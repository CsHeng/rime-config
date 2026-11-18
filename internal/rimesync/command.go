package rimesync

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"
)

// Command is a native frontend invocation with its completion model.
type Command struct {
	Executable string
	Args       []string
	// Completion is "process" (process exit is completion), "log" (the
	// process only submits work; completion is the frontend log event),
	// "state" (the process only submits work; completion is the durable state
	// Rime writes) or "unverifiable" (the result cannot be confirmed).
	Completion string
	// Mode selects which work the command performs: "sync" or "deploy".
	Mode   string
	LogDir string
	// UserDir is the Rime user data directory observed by "state".
	UserDir string
}

// Runner executes frontend commands.
type Runner struct {
	// Err receives child process output and diagnostics.
	Err io.Writer
	// Wait bounds the completion observation of asynchronous frontends.
	Wait time.Duration
	Poll time.Duration
	// Settle is how long a completed Rime state must stay unchanged before it
	// counts (default two seconds).
	Settle time.Duration
	Now    func() time.Time
}

// Result records one executed command.
type Result struct {
	Label      string
	Submission time.Time
	Completion string
	Elapsed    time.Duration
	Detail     string
}

// Run executes cmd and waits for a trustworthy completion signal. A submitted
// but unobserved asynchronous operation is an error, never a success.
func (r *Runner) Run(ctx context.Context, label string, c Command) (*Result, error) {
	if strings.TrimSpace(c.Executable) == "" {
		return nil, fmt.Errorf("%s: no executable configured", label)
	}
	if c.Completion == "none" || c.Completion == "" {
		return nil, fmt.Errorf("%s: this frontend cannot run this step on this platform", label)
	}
	exe, err := exec.LookPath(c.Executable)
	if err != nil {
		return nil, fmt.Errorf("%s: executable %s not found: %w", label, c.Executable, err)
	}
	mode := c.Mode
	if mode == "" {
		mode = "sync"
	}
	var offsets map[string]int64
	var probe *StateProbe
	switch c.Completion {
	case "log", "state":
		offsets, err = SnapshotLogs(c.LogDir)
		if err != nil {
			return nil, fmt.Errorf("%s: cannot observe completion: %w", label, err)
		}
		if c.Completion == "state" {
			// The log is the only failure channel next to the state files.
			if st, err := os.Stat(c.LogDir); err != nil || !st.IsDir() {
				return nil, fmt.Errorf("%s: cannot observe failures: log directory %s is missing", label, c.LogDir)
			}
			if probe, err = NewStateProbe(mode, c.UserDir); err != nil {
				return nil, fmt.Errorf("%s: cannot observe completion: %w", label, err)
			}
			probe.Settle = r.Settle
			if probe.Settle <= 0 {
				probe.Settle = 2 * time.Second
			}
			if mode == "deploy" {
				// last_build_time has one-second resolution: start in a
				// later second than the recorded build so a fast deploy
				// is always distinguishable.
				if err := waitUntilAfter(ctx, probe.BuildTime(), r.now); err != nil {
					return nil, fmt.Errorf("%s: %w", label, err)
				}
			}
		}
	}
	now := r.now()
	res := &Result{Label: label, Submission: now, Completion: c.Completion}
	cmd := exec.CommandContext(ctx, exe, c.Args...)
	if r.Err != nil {
		cmd.Stdout = r.Err
		cmd.Stderr = r.Err
	}
	if err := cmd.Run(); err != nil {
		return res, fmt.Errorf("%s: %s failed: %w", label, c.Executable, err)
	}
	switch c.Completion {
	case "process":
		res.Elapsed = r.now().Sub(now)
		return res, nil
	case "unverifiable":
		res.Elapsed = r.now().Sub(now)
		return res, fmt.Errorf("%s: %s exited 0 but this version does not report task results (Weasel Configurator::UpdateWorkspace ignores the deploy result), so success cannot be confirmed; treated as failure. Deploy from the IME menu, then run the sync", label, c.Executable)
	}

	wait := r.Wait
	if wait <= 0 {
		wait = 3 * time.Minute
	}
	waitCtx, cancel := context.WithTimeout(ctx, wait)
	defer cancel()
	watch := &LogWatch{
		Dir:     c.LogDir,
		Since:   now,
		Offsets: offsets,
		Mode:    mode,
		Poll:    r.Poll,
		Now:     r.Now,
	}
	if c.Completion == "log" {
		completion, err := watch.Wait(waitCtx)
		if err != nil {
			return res, fmt.Errorf("%s: submitted, but no completion event appeared within %s (log directory %s): %w", label, wait, c.LogDir, err)
		}
		res.Elapsed = r.now().Sub(now)
		res.Detail = completion.Detail
		if completion.Failure > 0 || completion.Success == 0 {
			return res, fmt.Errorf("%s: frontend reported failure (%s)", label, completion.Detail)
		}
		return res, nil
	}
	return r.waitState(waitCtx, label, wait, now, probe, watch, res)
}

// waitState polls the durable Rime state until the work is done. A visible log
// summary is authoritative; otherwise the state change marks completion and
// error lines of the maintenance worker thread mark failure.
func (r *Runner) waitState(ctx context.Context, label string, wait time.Duration, since time.Time, probe *StateProbe, watch *LogWatch, res *Result) (*Result, error) {
	poll := r.Poll
	if poll <= 0 {
		poll = 250 * time.Millisecond
	}
	pending := ""
	for {
		completion, err := watch.Scan()
		if err != nil {
			return res, fmt.Errorf("%s: read frontend log: %w", label, err)
		}
		if completion != nil {
			res.Elapsed = r.now().Sub(since)
			res.Detail = completion.Detail
			if completion.Failure > 0 || completion.Success == 0 {
				return res, fmt.Errorf("%s: frontend reported failure (%s)", label, completion.Detail)
			}
			return res, nil
		}
		if errs := watch.TaskErrors(); len(errs) > 0 {
			res.Elapsed = r.now().Sub(since)
			return res, fmt.Errorf("%s: frontend reported errors: %s", label, strings.Join(errs, "; "))
		}
		done, detail, err := probe.Done(since, r.now())
		if err != nil {
			return res, fmt.Errorf("%s: observe completion: %w", label, err)
		}
		if done {
			// Error lines are written unbuffered; read what is there now.
			completion, err := watch.Scan()
			if err != nil {
				return res, fmt.Errorf("%s: read frontend log: %w", label, err)
			}
			res.Elapsed = r.now().Sub(since)
			res.Detail = detail
			if completion != nil && (completion.Failure > 0 || completion.Success == 0) {
				return res, fmt.Errorf("%s: frontend reported failure (%s)", label, completion.Detail)
			}
			if errs := watch.TaskErrors(); len(errs) > 0 {
				return res, fmt.Errorf("%s: frontend reported errors: %s", label, strings.Join(errs, "; "))
			}
			return res, nil
		}
		pending = detail
		select {
		case <-ctx.Done():
			return res, fmt.Errorf("%s: submitted, but Rime did not finish within %s (%s): %w", label, wait, pending, ctx.Err())
		case <-time.After(poll):
		}
	}
}

// waitUntilAfter blocks until the clock is past the given Unix second.
func waitUntilAfter(ctx context.Context, sec int64, now func() time.Time) error {
	for {
		d := time.Unix(sec+1, 0).Sub(now())
		if d <= 0 || d > 2*time.Second {
			// Already later, or the recorded time is in the future (clock
			// change); waiting cannot help in the second case.
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(d):
		}
	}
}

func (r *Runner) now() time.Time {
	if r.Now != nil {
		return r.Now()
	}
	return time.Now()
}
