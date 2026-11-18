package rimesync

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestMain lets the test binary act as a fake frontend executable: when
// RIMESYNC_FAKE_ARGS is set it records its arguments there and exits with
// RIMESYNC_FAKE_EXIT. This keeps subprocess tests free of shell or Python.
func TestMain(m *testing.M) {
	if out := os.Getenv("RIMESYNC_FAKE_ARGS"); out != "" {
		_ = os.WriteFile(out, []byte(strings.Join(os.Args[1:], "\n")+"\n"), 0o644)
		code := 0
		fmt.Sscanf(os.Getenv("RIMESYNC_FAKE_EXIT"), "%d", &code)
		if os.Getenv("RIMESYNC_FAKE_SLEEP") != "" {
			time.Sleep(5 * time.Second)
		}
		os.Exit(code)
	}
	os.Exit(m.Run())
}

// fakeFrontend returns the test binary configured as a fake frontend.
func fakeFrontend(t *testing.T, exit int) (string, string) {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	argsFile := filepath.Join(t.TempDir(), "args.txt")
	t.Setenv("RIMESYNC_FAKE_ARGS", argsFile)
	t.Setenv("RIMESYNC_FAKE_EXIT", fmt.Sprint(exit))
	return exe, argsFile
}

func glogLine(level string, at time.Time, msg string) string {
	return glogThreadLine(level, at, "0x1", "file.cc:1] "+msg)
}

func glogThreadLine(level string, at time.Time, thread, msg string) string {
	return fmt.Sprintf("%s%s %s %s %s\n",
		level, at.Format("20060102"), at.Format("15:04:05.000000"), thread, msg)
}

func writeLog(t *testing.T, dir, name, content string) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func appendLog(t *testing.T, p, content string) {
	t.Helper()
	f, err := os.OpenFile(p, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o644)
	if err != nil {
		t.Error(err)
		return
	}
	defer f.Close()
	if _, err := f.WriteString(content); err != nil {
		t.Error(err)
	}
}

const logName = "rime.squirrel.host.user.log.INFO.20260101-000000.1234.log"

// --- log observation -------------------------------------------------------

func TestLogWatchSuccessWithDelayedStart(t *testing.T) {
	dir := t.TempDir()
	p := writeLog(t, dir, logName, "")
	since := time.Now()
	offsets, err := SnapshotLogs(dir)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		time.Sleep(100 * time.Millisecond)
		appendLog(t, p, glogLine("I", time.Now(), "synchronizing 2 user dicts."))
		time.Sleep(100 * time.Millisecond)
		appendLog(t, p, glogLine("I", time.Now(), "deployer.cc:97] 6 tasks ran: 6 success, 0 failure."))
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	w := &LogWatch{Dir: dir, Since: since, Offsets: offsets, Mode: "sync", Poll: 20 * time.Millisecond}
	got, err := w.Wait(ctx)
	<-done
	if err != nil {
		t.Fatalf("Wait: %v", err)
	}
	if !got.Observed || got.Success != 6 || got.Failure != 0 {
		t.Fatalf("completion parsed wrongly: %+v", got)
	}
}

func TestLogWatchReportsFailure(t *testing.T) {
	dir := t.TempDir()
	p := writeLog(t, dir, logName, "")
	since := time.Now()
	appendLog(t, p, glogLine("I", since, "synchronizing 1 user dicts."))
	appendLog(t, p, glogLine("I", since, "deployer.cc:97] 6 tasks ran: 4 success, 2 failure."))
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	w := &LogWatch{Dir: dir, Since: since, Mode: "sync", Poll: 20 * time.Millisecond}
	got, err := w.Wait(ctx)
	if err != nil {
		t.Fatalf("Wait: %v", err)
	}
	if got.Failure != 2 {
		t.Fatalf("failed tasks must be reported: %+v", got)
	}
}

func TestLogWatchTimeout(t *testing.T) {
	dir := t.TempDir()
	writeLog(t, dir, logName, "")
	since := time.Now()
	offsets, err := SnapshotLogs(dir)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	w := &LogWatch{Dir: dir, Since: since, Offsets: offsets, Mode: "sync", Poll: 20 * time.Millisecond}
	if _, err := w.Wait(ctx); err == nil {
		t.Fatal("a timeout must be an error, never a success")
	}
}

func TestLogWatchIgnoresStaleEvents(t *testing.T) {
	dir := t.TempDir()
	since := time.Now()
	old := since.Add(-time.Hour)
	writeLog(t, dir, logName, glogLine("I", old, "synchronizing 2 user dicts.")+
		glogLine("I", old, "deployer.cc:97] 6 tasks ran: 6 success, 0 failure."))

	t.Run("snapshot after event", func(t *testing.T) {
		offsets, err := SnapshotLogs(dir)
		if err != nil {
			t.Fatal(err)
		}
		w := &LogWatch{Dir: dir, Since: since, Offsets: offsets, Mode: "sync"}
		if got, err := w.Scan(); err != nil || got != nil {
			t.Fatalf("an old event must not complete this request: %+v %v", got, err)
		}
	})

	t.Run("old timestamps without snapshot", func(t *testing.T) {
		w := &LogWatch{Dir: dir, Since: since, Mode: "sync"}
		if got, err := w.Scan(); err != nil || got != nil {
			t.Fatalf("events older than the submission must be ignored: %+v %v", got, err)
		}
	})
}

func TestLogWatchIgnoresJustExpiredEventsInNewFile(t *testing.T) {
	dir := t.TempDir()
	since := time.Now()
	offsets, err := SnapshotLogs(dir)
	if err != nil {
		t.Fatal(err)
	}
	// A previous operation's records reach a newly created file after the
	// submission, but their timestamps predate it.
	stale := since.Add(-500 * time.Millisecond)
	appendLog(t, filepath.Join(dir, logName),
		glogLine("I", stale, "synchronizing 2 user dicts.")+
			glogLine("I", stale, "deployer.cc:97] 6 tasks ran: 6 success, 0 failure."))
	w := &LogWatch{Dir: dir, Since: since, Offsets: offsets, Mode: "sync"}
	if got, err := w.Scan(); err != nil || got != nil {
		t.Fatalf("just-expired events must not complete this request: %+v %v", got, err)
	}
}

func TestLogWatchDeployAcceptsSummaryWithoutSyncStart(t *testing.T) {
	dir := t.TempDir()
	since := time.Now()
	writeLog(t, dir, logName, glogLine("I", since, "deployer.cc:97] 6 tasks ran: 6 success, 0 failure."))
	w := &LogWatch{Dir: dir, Since: since, Mode: "deploy"}
	if got, err := w.Scan(); err != nil || got == nil {
		t.Fatalf("a deploy summary must complete a deploy wait: %+v %v", got, err)
	}
}

func TestLogWatchSyncIgnoresDeploySummaryWithoutStart(t *testing.T) {
	dir := t.TempDir()
	since := time.Now()
	writeLog(t, dir, logName, glogLine("I", since, "deployer.cc:97] 6 tasks ran: 6 success, 0 failure."))
	w := &LogWatch{Dir: dir, Since: since, Mode: "sync"}
	if got, err := w.Scan(); err != nil || got != nil {
		t.Fatalf("a summary without sync start must not complete a sync: %+v %v", got, err)
	}
}

func TestLogWatchIgnoresLinesWithoutTimestamp(t *testing.T) {
	dir := t.TempDir()
	since := time.Now()
	writeLog(t, dir, logName, "no timestamp: synchronizing 1 user dicts.\n"+
		"no timestamp: deployer.cc:97] 6 tasks ran: 6 success, 0 failure.\n")
	w := &LogWatch{Dir: dir, Since: since, Mode: "sync"}
	if got, err := w.Scan(); err != nil || got != nil {
		t.Fatalf("lines without timestamp must not count: %+v %v", got, err)
	}
}

func TestLogWatchRequiresStartAndEndInSameFile(t *testing.T) {
	dir := t.TempDir()
	since := time.Now()
	appendLog(t, filepath.Join(dir, "rime.squirrel.host.user.log.INFO.20260101-000000.1.log"),
		glogLine("I", since, "synchronizing 2 user dicts."))
	appendLog(t, filepath.Join(dir, "rime.squirrel.host.user.log.INFO.20260101-000000.2.log"),
		glogLine("I", since, "deployer.cc:97] 6 tasks ran: 6 success, 0 failure."))
	w := &LogWatch{Dir: dir, Since: since, Mode: "sync"}
	if got, err := w.Scan(); err != nil || got != nil {
		t.Fatalf("start and end from different files must not pair: %+v %v", got, err)
	}
}

func TestLogWatchKeepsPartialLines(t *testing.T) {
	dir := t.TempDir()
	since := time.Now()
	line := glogLine("I", since, "deployer.cc:97] 6 tasks ran: 6 success, 0 failure.")
	p := writeLog(t, dir, logName, line[:20])
	w := &LogWatch{Dir: dir, Since: since, Mode: "deploy"}
	if got, _ := w.Scan(); got != nil {
		t.Fatal("a partial line must not be parsed")
	}
	appendLog(t, p, line[20:])
	if got, err := w.Scan(); err != nil || got == nil {
		t.Fatalf("the completed line must be parsed: %+v %v", got, err)
	}
}

func TestLogWatchCollectsOnlyWorkerErrors(t *testing.T) {
	dir := t.TempDir()
	since := time.Now()
	writeLog(t, dir, logName,
		glogThreadLine("E", since, "0xMAIN", "user_dictionary.cc:87] failed to recruit dict entry 'x', unrecognized syllable: ni")+
			glogThreadLine("I", since, "0xWORK", "deployer.cc:80] running deployment tasks:")+
			glogThreadLine("E", since, "0xWORK", "deployment_tasks.cc:300] error building schema 'broken'")+
			glogThreadLine("E", since, "0xMAIN", "user_dictionary.cc:87] failed to recruit dict entry 'y', unrecognized syllable: hao"))
	w := &LogWatch{Dir: dir, Since: since, Mode: "deploy"}
	if _, err := w.Scan(); err != nil {
		t.Fatal(err)
	}
	errs := w.TaskErrors()
	if len(errs) != 1 || !strings.Contains(errs[0], "error building schema 'broken'") {
		t.Fatalf("TaskErrors = %q, want only the worker error", errs)
	}
}

// --- process runner ----------------------------------------------------------

func TestRunnerPassesArgumentsVerbatim(t *testing.T) {
	exe, argsFile := fakeFrontend(t, 0)
	r := &Runner{Err: &bytes.Buffer{}, Wait: 2 * time.Second}
	if _, err := r.Run(context.Background(), "squirrel/sync", Command{
		Executable: exe,
		Args:       []string{"--sync", "with space", "中文"},
		Completion: "process",
	}); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if got, want := readFile(t, argsFile), "--sync\nwith space\n中文\n"; got != want {
		t.Fatalf("arguments changed: %q, want %q", got, want)
	}
}

func TestRunnerPropagatesFailure(t *testing.T) {
	exe, _ := fakeFrontend(t, 3)
	r := &Runner{Err: &bytes.Buffer{}}
	_, err := r.Run(context.Background(), "weasel/sync", Command{Executable: exe, Completion: "process"})
	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) || exitErr.ExitCode() != 3 {
		t.Fatalf("a non-zero exit must keep its status: %v", err)
	}
}

func TestRunnerMissingExecutable(t *testing.T) {
	r := &Runner{Err: &bytes.Buffer{}}
	_, err := r.Run(context.Background(), "x", Command{Executable: filepath.Join(t.TempDir(), "nope"), Completion: "process"})
	if !errors.Is(err, exec.ErrNotFound) && !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a missing executable must fail with a not-found error: %v", err)
	}
}

func TestRunnerCancellation(t *testing.T) {
	exe, _ := fakeFrontend(t, 0)
	t.Setenv("RIMESYNC_FAKE_SLEEP", "1")
	r := &Runner{Err: &bytes.Buffer{}}
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	start := time.Now()
	if _, err := r.Run(ctx, "x", Command{Executable: exe, Completion: "process"}); err == nil {
		t.Fatal("cancellation must return an error")
	}
	if elapsed := time.Since(start); elapsed > 3*time.Second {
		t.Fatalf("cancellation was not handled promptly: %v", elapsed)
	}
}

func TestRunnerUnverifiableIsError(t *testing.T) {
	exe, _ := fakeFrontend(t, 0)
	r := &Runner{Err: &bytes.Buffer{}}
	if _, err := r.Run(context.Background(), "weasel/deploy", Command{Executable: exe, Completion: "unverifiable"}); err == nil {
		t.Fatal("an unverifiable deploy must be an error despite exit 0")
	}
}

// startAfterSubmit runs fn as the frontend's asynchronous work once the fake
// command was submitted.
func startAfterSubmit(t *testing.T, delay time.Duration, fn func()) <-chan struct{} {
	t.Helper()
	done := make(chan struct{})
	go func() {
		defer close(done)
		time.Sleep(delay)
		fn()
	}()
	return done
}

func TestRunnerLogCompletion(t *testing.T) {
	exe, _ := fakeFrontend(t, 0)
	logDir := t.TempDir()
	p := writeLog(t, logDir, logName, "")
	work := startAfterSubmit(t, 100*time.Millisecond, func() {
		now := time.Now()
		appendLog(t, p, glogLine("I", now, "synchronizing 2 user dicts.")+
			glogLine("I", now, "deployer.cc:97] 6 tasks ran: 6 success, 0 failure."))
	})
	r := &Runner{Err: &bytes.Buffer{}, Wait: 5 * time.Second, Poll: 20 * time.Millisecond}
	_, err := r.Run(context.Background(), "weasel/sync", Command{Executable: exe, Completion: "log", Mode: "sync", LogDir: logDir})
	<-work
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
}

func TestRunnerLogFailureAfterZeroExit(t *testing.T) {
	exe, _ := fakeFrontend(t, 0)
	logDir := t.TempDir()
	p := writeLog(t, logDir, logName, "")
	work := startAfterSubmit(t, 50*time.Millisecond, func() {
		now := time.Now()
		appendLog(t, p, glogLine("I", now, "synchronizing 1 user dicts.")+
			glogLine("I", now, "deployer.cc:97] 3 tasks ran: 0 success, 3 failure."))
	})
	r := &Runner{Err: &bytes.Buffer{}, Wait: 5 * time.Second, Poll: 20 * time.Millisecond}
	_, err := r.Run(context.Background(), "weasel/sync", Command{Executable: exe, Completion: "log", Mode: "sync", LogDir: logDir})
	<-work
	if err == nil || !strings.Contains(err.Error(), "0 success, 3 failure") {
		t.Fatalf("a failed task summary must be an error: %v", err)
	}
}

func TestRunnerLogCompletionTimeoutIsError(t *testing.T) {
	exe, _ := fakeFrontend(t, 0)
	logDir := t.TempDir()
	writeLog(t, logDir, logName, "")
	r := &Runner{Err: &bytes.Buffer{}, Wait: 200 * time.Millisecond, Poll: 20 * time.Millisecond}
	_, err := r.Run(context.Background(), "squirrel/sync", Command{Executable: exe, Completion: "log", Mode: "sync", LogDir: logDir})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("an unobserved completion must time out: %v", err)
	}
}

// --- durable state observation ----------------------------------------------

// rimeUserDir creates a Rime user directory with an installation.yaml whose
// sync_dir uses the quoting librime writes.
func rimeUserDir(t *testing.T, dicts ...string) (userDir, snapshots string) {
	t.Helper()
	root := t.TempDir()
	userDir = filepath.Join(root, "Rime")
	syncDir := filepath.Join(root, "Cloud Docs", "RimeUserSync")
	id := "Squirrel-Someone's-Mac"
	for _, d := range dicts {
		if err := os.MkdirAll(filepath.Join(userDir, d+".userdb"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	writeLog(t, userDir, "installation.yaml", fmt.Sprintf("distribution_code_name: Squirrel\ninstallation_id: %q\nsync_dir: %q\n", id, syncDir))
	writeLog(t, userDir, "user.yaml", "var:\n  last_build_time: 1000\n  option:\n    emoji: true\n")
	snapshots = filepath.Join(syncDir, id)
	if err := os.MkdirAll(snapshots, 0o755); err != nil {
		t.Fatal(err)
	}
	return userDir, snapshots
}

func setBuildTime(t *testing.T, userDir string, at time.Time) {
	writeLog(t, userDir, "user.yaml", fmt.Sprintf("var:\n  last_build_time: %d\n  option:\n    emoji: true\n", at.Unix()))
}

func TestSnapshotDirFromInstallation(t *testing.T) {
	userDir, snapshots := rimeUserDir(t)
	got, err := SnapshotDir(userDir)
	if err != nil {
		t.Fatal(err)
	}
	if got != snapshots {
		t.Fatalf("SnapshotDir = %q, want %q", got, snapshots)
	}

	plain := t.TempDir()
	writeLog(t, plain, "installation.yaml", "installation_id: 'it''s-me'\n")
	if got, err := SnapshotDir(plain); err != nil || got != filepath.Join(plain, "sync", "it's-me") {
		t.Fatalf("default sync_dir = %q, %v", got, err)
	}

	missing := t.TempDir()
	writeLog(t, missing, "installation.yaml", "sync_dir: /x\n")
	if _, err := SnapshotDir(missing); err == nil {
		t.Fatal("an installation without installation_id must fail")
	}
}

// TestRunnerStateDeployDoesNotNeedTheLog models the production failure: the
// frontend finished the deploy and wrote user.yaml, but glog kept the
// completion line in its buffer, so the log file never shows it.
func TestRunnerStateDeployDoesNotNeedTheLog(t *testing.T) {
	exe, _ := fakeFrontend(t, 0)
	userDir, _ := rimeUserDir(t)
	logDir := t.TempDir()
	p := writeLog(t, logDir, logName, "")
	work := startAfterSubmit(t, 150*time.Millisecond, func() {
		appendLog(t, p, glogThreadLine("I", time.Now(), "0xMAIN", "deployer.cc:119] starting work thread for 3 tasks."))
		setBuildTime(t, userDir, time.Now())
		// "N tasks ran" stays in the frontend's buffer: nothing more is written.
	})
	r := &Runner{Err: &bytes.Buffer{}, Wait: 5 * time.Second, Poll: 20 * time.Millisecond}
	res, err := r.Run(context.Background(), "squirrel/deploy", Command{
		Executable: exe, Completion: "state", Mode: "deploy", LogDir: logDir, UserDir: userDir,
	})
	<-work
	if err != nil {
		t.Fatalf("a deploy whose state changed must succeed without the log line: %v", err)
	}
	if !strings.Contains(res.Detail, "last_build_time") {
		t.Fatalf("Detail = %q, want the state evidence", res.Detail)
	}
	if res.Elapsed > 3*time.Second {
		t.Fatalf("completion was not observed promptly: %v", res.Elapsed)
	}
}

func TestRunnerStateDeployTimesOutWithoutStateChange(t *testing.T) {
	exe, _ := fakeFrontend(t, 0)
	userDir, _ := rimeUserDir(t)
	r := &Runner{Err: &bytes.Buffer{}, Wait: 200 * time.Millisecond, Poll: 20 * time.Millisecond}
	_, err := r.Run(context.Background(), "squirrel/deploy", Command{
		Executable: exe, Completion: "state", Mode: "deploy", LogDir: t.TempDir(), UserDir: userDir,
	})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("an unchanged build time must time out: %v", err)
	}
}

func TestRunnerStateDeployReportsWorkerErrors(t *testing.T) {
	exe, _ := fakeFrontend(t, 0)
	userDir, _ := rimeUserDir(t)
	logDir := t.TempDir()
	p := writeLog(t, logDir, logName, "")
	work := startAfterSubmit(t, 50*time.Millisecond, func() {
		now := time.Now()
		// An ERROR line flushes the buffered INFO lines before it.
		appendLog(t, p, glogThreadLine("I", now, "0xWORK", "deployer.cc:80] running deployment tasks:")+
			glogThreadLine("E", now, "0xWORK", "deployment_tasks.cc:300] error building schema 'broken'"))
		setBuildTime(t, userDir, now)
	})
	r := &Runner{Err: &bytes.Buffer{}, Wait: 5 * time.Second, Poll: 20 * time.Millisecond}
	_, err := r.Run(context.Background(), "squirrel/deploy", Command{
		Executable: exe, Completion: "state", Mode: "deploy", LogDir: logDir, UserDir: userDir,
	})
	<-work
	if err == nil || !strings.Contains(err.Error(), "error building schema 'broken'") {
		t.Fatalf("a worker error must fail the deploy: %v", err)
	}
}

func TestRunnerStateDeployIgnoresTypingErrors(t *testing.T) {
	exe, _ := fakeFrontend(t, 0)
	userDir, _ := rimeUserDir(t)
	logDir := t.TempDir()
	p := writeLog(t, logDir, logName, "")
	work := startAfterSubmit(t, 50*time.Millisecond, func() {
		now := time.Now()
		appendLog(t, p, glogThreadLine("E", now, "0xMAIN", "user_dictionary.cc:87] failed to recruit dict entry 'x', unrecognized syllable: ni"))
		setBuildTime(t, userDir, now)
	})
	r := &Runner{Err: &bytes.Buffer{}, Wait: 5 * time.Second, Poll: 20 * time.Millisecond}
	_, err := r.Run(context.Background(), "squirrel/deploy", Command{
		Executable: exe, Completion: "state", Mode: "deploy", LogDir: logDir, UserDir: userDir,
	})
	<-work
	if err != nil {
		t.Fatalf("errors from the IME thread must not fail the deploy: %v", err)
	}
}

func TestRunnerStateSyncWaitsForEverySnapshot(t *testing.T) {
	exe, _ := fakeFrontend(t, 0)
	userDir, snapshots := rimeUserDir(t, "wanxiang", "en")
	// A snapshot from an earlier sync must not count.
	old := time.Now().Add(-time.Hour)
	writeLog(t, snapshots, "en.userdb.txt", "old\n")
	if err := os.Chtimes(filepath.Join(snapshots, "en.userdb.txt"), old, old); err != nil {
		t.Fatal(err)
	}
	work := startAfterSubmit(t, 100*time.Millisecond, func() {
		writeLog(t, snapshots, "en.userdb.txt", "new\n")
		time.Sleep(300 * time.Millisecond)
		writeLog(t, snapshots, "wanxiang.userdb.txt", "new\n")
	})
	r := &Runner{Err: &bytes.Buffer{}, Wait: 5 * time.Second, Poll: 20 * time.Millisecond}
	res, err := r.Run(context.Background(), "squirrel/sync", Command{
		Executable: exe, Completion: "state", Mode: "sync", LogDir: t.TempDir(), UserDir: userDir,
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if _, statErr := os.Stat(filepath.Join(snapshots, "wanxiang.userdb.txt")); statErr != nil {
		t.Fatal("the sync was reported complete before the last snapshot was written")
	}
	<-work
	if !strings.Contains(res.Detail, "2 user dictionary snapshots") {
		t.Fatalf("Detail = %q", res.Detail)
	}
}

func TestRunnerStateSyncTimesOutOnStaleSnapshots(t *testing.T) {
	exe, _ := fakeFrontend(t, 0)
	userDir, snapshots := rimeUserDir(t, "wanxiang")
	writeLog(t, snapshots, "wanxiang.userdb.txt", "old\n")
	r := &Runner{Err: &bytes.Buffer{}, Wait: 200 * time.Millisecond, Poll: 20 * time.Millisecond}
	_, err := r.Run(context.Background(), "squirrel/sync", Command{
		Executable: exe, Completion: "state", Mode: "sync", LogDir: t.TempDir(), UserDir: userDir,
	})
	if !errors.Is(err, context.DeadlineExceeded) || !strings.Contains(err.Error(), "wanxiang") {
		t.Fatalf("unchanged snapshots must time out naming the pending dictionary: %v", err)
	}
}

func TestRunnerStateSyncNeedsInstallationID(t *testing.T) {
	exe, argsFile := fakeFrontend(t, 0)
	userDir := t.TempDir()
	r := &Runner{Err: &bytes.Buffer{}, Wait: time.Second}
	if _, err := r.Run(context.Background(), "squirrel/sync", Command{
		Executable: exe, Completion: "state", Mode: "sync", LogDir: t.TempDir(), UserDir: userDir,
	}); err == nil || !strings.Contains(err.Error(), "installation.yaml") {
		t.Fatalf("an unobservable sync must fail: %v", err)
	}
	if _, err := os.Stat(argsFile); !os.IsNotExist(err) {
		t.Fatal("the command must not be submitted when completion cannot be observed")
	}
}

func TestLogWatchCollectsErrorsAfterSummaryInSameChunk(t *testing.T) {
	dir := t.TempDir()
	since := time.Now()
	writeLog(t, dir, logName,
		glogThreadLine("I", since, "0xWORK", "deployer.cc:80] running deployment tasks:")+
			glogThreadLine("I", since, "0xWORK", "deployer.cc:97] 3 tasks ran: 3 success, 0 failure.")+
			glogThreadLine("I", since, "0xWORK", "deployer.cc:80] running deployment tasks:")+
			glogThreadLine("E", since, "0xWORK", "user_db.cc:200] failed to export 'wanxiang'"))
	w := &LogWatch{Dir: dir, Since: since, Mode: "deploy"}
	if got, err := w.Scan(); err != nil || got == nil {
		t.Fatalf("the summary must complete the scan: %+v %v", got, err)
	}
	// No further append: the error written with the summary is already known.
	if errs := w.TaskErrors(); len(errs) != 1 || !strings.Contains(errs[0], "failed to export") {
		t.Fatalf("TaskErrors = %q, want the error that followed the summary", errs)
	}
}

func TestRunnerStateFailsWithoutLogDir(t *testing.T) {
	exe, argsFile := fakeFrontend(t, 0)
	userDir, _ := rimeUserDir(t)
	r := &Runner{Err: &bytes.Buffer{}, Wait: time.Second}
	_, err := r.Run(context.Background(), "squirrel/deploy", Command{
		Executable: exe, Completion: "state", Mode: "deploy", LogDir: filepath.Join(t.TempDir(), "missing"), UserDir: userDir,
	})
	if err == nil || !strings.Contains(err.Error(), "log directory") {
		t.Fatalf("a state deploy without a failure channel must fail: %v", err)
	}
	if _, err := os.Stat(argsFile); !os.IsNotExist(err) {
		t.Fatal("the command must not be submitted without a failure channel")
	}
}

// TestRunnerStateDeployFailureSummaryWithoutErrorLine covers a task that
// returns false without an ERROR line: only the summary shows the failure.
func TestRunnerStateDeployFailureSummaryWithoutErrorLine(t *testing.T) {
	exe, _ := fakeFrontend(t, 0)
	userDir, _ := rimeUserDir(t)
	logDir := t.TempDir()
	p := writeLog(t, logDir, logName, "")
	work := startAfterSubmit(t, 50*time.Millisecond, func() {
		setBuildTime(t, userDir, time.Now())
		time.Sleep(100 * time.Millisecond)
		appendLog(t, p, glogThreadLine("I", time.Now(), "0xWORK", "deployer.cc:97] 3 tasks ran: 2 success, 1 failure."))
	})
	r := &Runner{Err: &bytes.Buffer{}, Wait: 5 * time.Second, Poll: 20 * time.Millisecond, Settle: 300 * time.Millisecond}
	_, err := r.Run(context.Background(), "squirrel/deploy", Command{
		Executable: exe, Completion: "state", Mode: "deploy", LogDir: logDir, UserDir: userDir,
	})
	<-work
	if err == nil || !strings.Contains(err.Error(), "1 failure") {
		t.Fatalf("a visible failure summary must fail the deploy: %v", err)
	}
}

// TestRunnerStateDeploySameSecond guards the one-second resolution of
// last_build_time: a fast deploy right after an earlier one must still be seen.
func TestRunnerStateDeploySameSecond(t *testing.T) {
	exe, _ := fakeFrontend(t, 0)
	userDir, _ := rimeUserDir(t)
	setBuildTime(t, userDir, time.Now())
	logDir := t.TempDir()
	writeLog(t, logDir, logName, "")
	argsFile := os.Getenv("RIMESYNC_FAKE_ARGS")
	work := startAfterSubmit(t, 0, func() {
		// Write the new build time as soon as the command was submitted.
		deadline := time.Now().Add(4 * time.Second)
		for time.Now().Before(deadline) {
			if _, err := os.Stat(argsFile); err == nil {
				setBuildTime(t, userDir, time.Now())
				return
			}
			time.Sleep(5 * time.Millisecond)
		}
	})
	r := &Runner{Err: &bytes.Buffer{}, Wait: 4 * time.Second, Poll: 20 * time.Millisecond, Settle: 100 * time.Millisecond}
	_, err := r.Run(context.Background(), "squirrel/deploy", Command{
		Executable: exe, Completion: "state", Mode: "deploy", LogDir: logDir, UserDir: userDir,
	})
	<-work
	if err != nil {
		t.Fatalf("a deploy finishing in the same second as the previous one must be observed: %v", err)
	}
}

// TestRunnerStateSyncWaitsForSlowSnapshotWrite models librime writing the last
// snapshot in place over several flushes.
func TestRunnerStateSyncWaitsForSlowSnapshotWrite(t *testing.T) {
	exe, _ := fakeFrontend(t, 0)
	userDir, snapshots := rimeUserDir(t, "wanxiang")
	const chunks = 5
	work := startAfterSubmit(t, 50*time.Millisecond, func() {
		p := writeLog(t, snapshots, "wanxiang.userdb.txt", "")
		for i := 0; i < chunks; i++ {
			time.Sleep(100 * time.Millisecond)
			appendLog(t, p, "line\n")
		}
	})
	r := &Runner{Err: &bytes.Buffer{}, Wait: 5 * time.Second, Poll: 20 * time.Millisecond, Settle: 400 * time.Millisecond}
	_, err := r.Run(context.Background(), "squirrel/sync", Command{
		Executable: exe, Completion: "state", Mode: "sync", LogDir: t.TempDir(), UserDir: userDir,
	})
	got := readFile(t, filepath.Join(snapshots, "wanxiang.userdb.txt"))
	<-work
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if want := strings.Repeat("line\n", chunks); got != want {
		t.Fatalf("sync reported complete during the export: snapshot %q", got)
	}
}

func TestRunnerStateSyncWithoutUserDictsFails(t *testing.T) {
	exe, argsFile := fakeFrontend(t, 0)
	userDir, _ := rimeUserDir(t)
	r := &Runner{Err: &bytes.Buffer{}, Wait: time.Second}
	_, err := r.Run(context.Background(), "squirrel/sync", Command{
		Executable: exe, Completion: "state", Mode: "sync", LogDir: t.TempDir(), UserDir: userDir,
	})
	if err == nil || !strings.Contains(err.Error(), "userdb") {
		t.Fatalf("a sync with nothing to observe must fail: %v", err)
	}
	if _, err := os.Stat(argsFile); !os.IsNotExist(err) {
		t.Fatal("the command must not be submitted when completion cannot be observed")
	}
}

func readFile(t *testing.T, p string) string {
	t.Helper()
	data, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// --- Unison ------------------------------------------------------------------

func TestUnisonValidation(t *testing.T) {
	a := t.TempDir()
	b := t.TempDir()
	nested := filepath.Join(a, "inner")
	if err := os.Mkdir(nested, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, o := range []UnisonOptions{
		{OneDriveDir: "", ICloudDir: b},
		{OneDriveDir: a, ICloudDir: filepath.Join(a, "missing")},
		{OneDriveDir: a, ICloudDir: a},
		{OneDriveDir: a, ICloudDir: nested},
		{OneDriveDir: "relative", ICloudDir: b},
	} {
		if err := RunUnison(context.Background(), o); err == nil {
			t.Fatalf("invalid cloud sync config must be rejected: %+v", o)
		}
	}
}

func TestUnisonDryRunPrintsPlan(t *testing.T) {
	a := t.TempDir()
	b := t.TempDir()
	var out bytes.Buffer
	o := UnisonOptions{Unison: "/nonexistent/unison", OneDriveDir: a, ICloudDir: b, ArchiveDir: "/work/unison", DryRun: true, Out: &out}
	if err := RunUnison(context.Background(), o); err != nil {
		t.Fatalf("dry-run must not need Unison: %v", err)
	}
	for _, want := range []string{a, b, "UNISON=/work/unison"} {
		if !strings.Contains(out.String(), want) {
			t.Fatalf("plan is missing %q: %s", want, out.String())
		}
	}
}

func TestUnisonWithRealEngine(t *testing.T) {
	unison, err := exec.LookPath("unison")
	if err != nil {
		t.Skip("unison is not installed")
	}
	root := t.TempDir()
	one := filepath.Join(root, "one")
	cloud := filepath.Join(root, "cloud")
	archive := filepath.Join(root, "work", "unison")
	ambient := filepath.Join(root, "ambient")
	for _, d := range []string{one, cloud, ambient} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	// An inherited UNISON must not redirect the tool-owned archive.
	t.Setenv("UNISON", ambient)
	write := func(dir, name, content string, mtime time.Time) {
		t.Helper()
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
		if !mtime.IsZero() {
			if err := os.Chtimes(p, mtime, mtime); err != nil {
				t.Fatal(err)
			}
		}
	}
	base := time.Now().Add(-time.Hour).Truncate(time.Second)
	write(one, "a.txt", "from-onedrive\n", base)
	write(cloud, "b.txt", "from-icloud\n", time.Time{})
	write(one, "skip.tmp", "temporary\n", time.Time{})
	write(cloud, ".DS_Store", "finder\n", time.Time{})
	var logs bytes.Buffer
	o := UnisonOptions{Unison: unison, OneDriveDir: one, ICloudDir: cloud, ArchiveDir: archive, Out: &logs, Err: &logs}
	if err := RunUnison(context.Background(), o); err != nil {
		t.Fatalf("first run: %v\n%s", err, logs.String())
	}
	if got := readFile(t, filepath.Join(cloud, "a.txt")); got != "from-onedrive\n" {
		t.Fatalf("OneDrive -> iCloud: %q", got)
	}
	if st, err := os.Stat(filepath.Join(cloud, "a.txt")); err != nil || !st.ModTime().Equal(base) {
		t.Fatalf("-times must keep the modification time: %v %v", st.ModTime(), err)
	}
	if got := readFile(t, filepath.Join(one, "b.txt")); got != "from-icloud\n" {
		t.Fatalf("iCloud -> OneDrive: %q", got)
	}
	if exists(filepath.Join(cloud, "skip.tmp")) || exists(filepath.Join(one, ".DS_Store")) {
		t.Fatal("*.tmp and .DS_Store must be ignored")
	}
	if entries, _ := os.ReadDir(archive); len(entries) == 0 {
		t.Fatal("the archive must live in the tool-owned directory")
	}
	if entries, _ := os.ReadDir(ambient); len(entries) != 0 {
		t.Fatalf("the ambient UNISON directory was used: %v", entries)
	}

	// Changes on both sides, a deletion, and a conflict resolved by mtime.
	write(one, "b.txt", "changed-on-one\n", time.Time{})
	write(cloud, "c.txt", "new-on-cloud\n", time.Time{})
	if err := os.Remove(filepath.Join(cloud, "a.txt")); err != nil {
		t.Fatal(err)
	}
	write(one, "conflict.txt", "seed\n", base)
	if err := RunUnison(context.Background(), o); err != nil {
		t.Fatalf("second run: %v\n%s", err, logs.String())
	}
	write(one, "conflict.txt", "older edit\n", base.Add(10*time.Minute))
	write(cloud, "conflict.txt", "newer edit\n", base.Add(20*time.Minute))
	if err := RunUnison(context.Background(), o); err != nil {
		t.Fatalf("third run: %v\n%s", err, logs.String())
	}
	if got := readFile(t, filepath.Join(cloud, "b.txt")); got != "changed-on-one\n" {
		t.Fatalf("modification not synced to iCloud: %q", got)
	}
	if got := readFile(t, filepath.Join(one, "c.txt")); got != "new-on-cloud\n" {
		t.Fatalf("addition not synced to OneDrive: %q", got)
	}
	if exists(filepath.Join(one, "a.txt")) {
		t.Fatal("deletion not synced to OneDrive")
	}
	for _, dir := range []string{one, cloud} {
		if got := readFile(t, filepath.Join(dir, "conflict.txt")); got != "newer edit\n" {
			t.Fatalf("conflict must resolve to the newer copy in %s: %q", dir, got)
		}
	}
}

func exists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}
