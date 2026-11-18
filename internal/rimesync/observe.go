// Package rimesync runs the native Rime deploy/sync commands and the optional
// macOS Unison cloud sync, and observes whether asynchronous work really
// finished.
package rimesync

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Completion is the observed outcome of an asynchronous frontend operation.
type Completion struct {
	Observed bool
	Success  int
	Failure  int
	Detail   string
}

// LogWatch observes an append-only glog style frontend log file.
//
// glog buffers INFO lines inside the frontend process and only writes them
// when a later log call happens after the buffer interval, so a long-running
// IME such as Squirrel may hold its completion line for minutes. ERROR lines
// are written immediately and flush the buffered lines before them. A log
// watch alone is therefore only a reliable completion signal for frontends
// whose process exits when the work is done.
type LogWatch struct {
	Dir string
	// Since is the moment the frontend command was submitted. Events older
	// than this are ignored so a stale event is never mistaken for ours.
	Since time.Time
	// Offsets is the per-file size snapshot taken before submitting the
	// command. Only content appended after the snapshot is considered.
	Offsets map[string]int64
	// Mode is "sync" or "deploy".
	Mode string
	Poll time.Duration
	Now  func() time.Time

	state *watchState
}

var (
	reGlogLine  = regexp.MustCompile(`^([IWEF])(\d{4})(\d{2})(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{6}) +(\S+) `)
	reSyncStart = regexp.MustCompile(`synchronizing (\d+) user dicts\.`)
	reDeployEnd = regexp.MustCompile(`deployer\.cc:\d+\]\s+(\d+) tasks ran: (\d+) success, (\d+) failure\.`)
	reWorker    = regexp.MustCompile(`deployer\.cc:\d+\]\s+running deployment tasks:`)
)

// SnapshotLogs records the current size of every frontend log file. A missing
// directory yields an empty snapshot; the watcher then waits for it to appear.
func SnapshotLogs(dir string) (map[string]int64, error) {
	offsets := map[string]int64{}
	if dir == "" {
		return offsets, errors.New("no log directory configured")
	}
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return offsets, nil
	}
	if err != nil {
		return nil, err
	}
	for _, e := range entries {
		if e.IsDir() || !isInfoLog(e.Name()) {
			continue
		}
		info, err := os.Stat(filepath.Join(dir, e.Name()))
		if err != nil || !info.Mode().IsRegular() {
			continue
		}
		offsets[e.Name()] = info.Size()
	}
	return offsets, nil
}

func isInfoLog(name string) bool {
	return strings.HasSuffix(name, ".log") && strings.Contains(name, ".INFO.")
}

type watchState struct {
	offsets map[string]int64
	partial map[string]string
	// started is tracked per log file: a sync start and its completion must
	// come from the same frontend log stream, never from two unrelated files.
	started map[string]bool
	// workers holds, per log file, the thread ids that announced running our
	// maintenance tasks. Error lines of those threads are task failures;
	// errors of other threads (for example typing on the IME thread) are not.
	workers map[string]map[string]bool
	// taskErrors are error lines written by a maintenance worker thread.
	taskErrors []string
}

func (w *LogWatch) init() {
	if w.state != nil {
		return
	}
	w.state = &watchState{
		offsets: map[string]int64{},
		partial: map[string]string{},
		started: map[string]bool{},
		workers: map[string]map[string]bool{},
	}
	for name, off := range w.Offsets {
		w.state.offsets[name] = off
	}
	if w.Mode == "" {
		w.Mode = "sync"
	}
}

// TaskErrors returns the error lines written by maintenance worker threads
// since the watch started.
func (w *LogWatch) TaskErrors() []string {
	if w.state == nil {
		return nil
	}
	return append([]string(nil), w.state.taskErrors...)
}

// Wait polls until the completion event appears or ctx is done. On timeout the
// caller must report an incomplete operation instead of a success.
func (w *LogWatch) Wait(ctx context.Context) (Completion, error) {
	if w.Dir == "" {
		return Completion{}, errors.New("no log directory configured")
	}
	poll := w.Poll
	if poll <= 0 {
		poll = 250 * time.Millisecond
	}
	for {
		done, err := w.Scan()
		if err != nil {
			return Completion{}, err
		}
		if done != nil {
			return *done, nil
		}
		select {
		case <-ctx.Done():
			return Completion{}, ctx.Err()
		case <-time.After(poll):
		}
	}
}

// Scan reads newly appended log content once. It returns the completion event
// when one was observed and records worker error lines for TaskErrors.
func (w *LogWatch) Scan() (*Completion, error) {
	w.init()
	if w.Dir == "" {
		return nil, nil
	}
	entries, err := os.ReadDir(w.Dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() || !isInfoLog(e.Name()) {
			continue
		}
		names = append(names, e.Name())
	}
	sort.Strings(names)

	for _, name := range names {
		done, err := w.scanFile(filepath.Join(w.Dir, name))
		if err != nil {
			return nil, err
		}
		if done != nil {
			return done, nil
		}
	}
	return nil, nil
}

func (w *LogWatch) scanFile(p string) (*Completion, error) {
	state := w.state
	name := filepath.Base(p)
	info, err := os.Stat(p)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, nil
	}
	offset := state.offsets[name]
	if info.Size() < offset {
		// The file was replaced or truncated; read it from the start.
		offset = 0
	}
	if info.Size() == offset {
		return nil, nil
	}
	f, err := os.Open(p)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	defer f.Close()
	if _, err := f.Seek(offset, io.SeekStart); err != nil {
		return nil, err
	}
	chunk := make([]byte, info.Size()-offset)
	if _, err := io.ReadFull(f, chunk); err != nil {
		return nil, err
	}
	state.offsets[name] = info.Size()

	// Only newline terminated lines are events; a partially written trailing
	// line is kept for the next poll. Lines after a completion event are still
	// read so worker errors written next to it are not lost.
	buffer := state.partial[name] + string(chunk)
	lines := strings.Split(buffer, "\n")
	state.partial[name] = lines[len(lines)-1]
	var first *Completion
	for _, line := range lines[:len(lines)-1] {
		if done := w.handleLine(name, line); done != nil && first == nil {
			first = done
		}
	}
	return first, nil
}

func (w *LogWatch) handleLine(name, line string) *Completion {
	state := w.state
	// Fail closed: without a parseable timestamp the event cannot be proven to
	// belong to this request, so it is ignored.
	ts, thread, severity, ok := parseGlogLine(line)
	if !ok {
		return nil
	}
	if ts.Before(w.Since) {
		return nil
	}
	if reWorker.MatchString(line) {
		if state.workers[name] == nil {
			state.workers[name] = map[string]bool{}
		}
		state.workers[name][thread] = true
		return nil
	}
	if (severity == "E" || severity == "F") && state.workers[name][thread] {
		state.taskErrors = append(state.taskErrors, strings.TrimSpace(line))
		return nil
	}
	if reSyncStart.MatchString(line) {
		state.started[name] = true
		return nil
	}
	m := reDeployEnd.FindStringSubmatch(line)
	if m == nil {
		return nil
	}
	if w.Mode == "sync" && !state.started[name] {
		// A deployment summary without a sync start in the same log stream
		// belongs to another operation and must not count as our completion.
		return nil
	}
	success, _ := strconv.Atoi(m[2])
	failure, _ := strconv.Atoi(m[3])
	return &Completion{Observed: true, Success: success, Failure: failure, Detail: strings.TrimSpace(line)}
}

func parseGlogLine(line string) (time.Time, string, string, bool) {
	m := reGlogLine.FindStringSubmatch(line)
	if m == nil {
		return time.Time{}, "", "", false
	}
	atoi := func(s string) int { n, _ := strconv.Atoi(s); return n }
	ts := time.Date(
		atoi(m[2]), time.Month(atoi(m[3])), atoi(m[4]),
		atoi(m[5]), atoi(m[6]), atoi(m[7]), atoi(m[8])*1000,
		time.Local,
	)
	return ts, m[9], m[1], true
}
