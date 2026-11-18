package app

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"rime-config-go/internal/config"
	"rime-config-go/internal/rimesync"
	"rime-config-go/internal/setup"
	"rime-config-go/internal/update"
)

// Version is the tool version reported by --version.
const Version = "0.2.0"

// App owns the command line lifecycle of one invocation.
type App struct {
	Stdout io.Writer
	Stderr io.Writer
	// Platform is the target platform; runtime.GOOS by default and injectable
	// for tests.
	Platform string
	// Executable locates the default configuration next to the binary.
	Executable string
	Getenv     func(string) string
	Now        func() time.Time
	// Settle overrides how long completed Rime state must stay unchanged;
	// zero keeps the runner default. Tests shorten it.
	Settle time.Duration
}

// New creates an App bound to the current process environment.
func New() *App {
	return &App{
		Stdout:   os.Stdout,
		Stderr:   os.Stderr,
		Platform: runtime.GOOS,
		Getenv:   os.Getenv,
		Now:      time.Now,
	}
}

type frontendPlan struct {
	frontend config.Frontend
	target   string
}

// Run executes one command line invocation and returns the exit code.
func (a *App) Run(ctx context.Context, args []string) int {
	opts, usage, err := ParseArgs(args)
	if errors.Is(err, flag.ErrHelp) {
		fmt.Fprint(a.Stdout, usage)
		return ExitOK
	}
	if err != nil {
		fmt.Fprintf(a.Stderr, "error: %v\n\n%s", err, usage)
		return ExitUsage
	}
	if opts.ShowVersion {
		fmt.Fprintf(a.Stdout, "rime-config %s (%s)\n", Version, a.Platform)
		return ExitOK
	}
	if err := opts.Validate(a.Platform); err != nil {
		fmt.Fprintf(a.Stderr, "error: invalid options: %v\n", err)
		return ExitUsage
	}
	if opts.Setup {
		return a.runSetup(opts)
	}

	cfgPath := opts.ConfigPath
	if cfgPath == "" {
		cfgPath = a.defaultConfigPath()
		if cfgPath == "" {
			return ExitUsage
		}
	}
	cfg, err := config.Load(cfgPath)
	if err != nil {
		fmt.Fprintf(a.Stderr, "error: %v\n", err)
		return ExitUsage
	}
	plans, err := a.plan(cfg, opts)
	if err != nil {
		fmt.Fprintf(a.Stderr, "error: config: %v\n", err)
		return ExitUsage
	}
	if err := a.preflight(cfg, plans, opts); err != nil {
		fmt.Fprintf(a.Stderr, "error: preflight: %v\n", err)
		return ExitUsage
	}
	if opts.SyncOnly {
		return a.runNativeSteps(ctx, cfg, plans, opts)
	}
	return a.runUpdate(ctx, cfg, plans, opts)
}

func (a *App) defaultConfigPath() string {
	exe := a.Executable
	if exe == "" {
		resolved, err := os.Executable()
		if err != nil {
			fmt.Fprintf(a.Stderr, "error: cannot locate the executable: %v\n", err)
			return ""
		}
		exe = resolved
	}
	return config.DefaultPath(exe)
}

// runSetup detects the local Rime installation and writes frontends.json. It
// never writes any other file and never touches a Rime target.
func (a *App) runSetup(opts *Options) int {
	cfgPath := opts.ConfigPath
	if cfgPath == "" {
		cfgPath = a.defaultConfigPath()
		if cfgPath == "" {
			return ExitUsage
		}
	}
	home, err := os.UserHomeDir()
	if err != nil {
		fmt.Fprintf(a.Stderr, "error: setup: cannot determine the home directory: %v\n", err)
		return ExitFailure
	}
	res, err := setup.Run(setup.Options{
		Home:       home,
		Platform:   a.Platform,
		ConfigPath: cfgPath,
		DryRun:     opts.DryRun,
		Force:      opts.Force,
		Getenv:     a.Getenv,
	})
	if err != nil {
		fmt.Fprintf(a.Stderr, "error: setup: %v\n", err)
		return ExitFailure
	}
	if opts.DryRun {
		if _, err := a.Stdout.Write(res.ConfigJSON); err != nil {
			fmt.Fprintf(a.Stderr, "error: setup: write generated config: %v\n", err)
			return ExitFailure
		}
		for _, note := range res.Notes {
			fmt.Fprintln(a.Stderr, note)
		}
		return ExitOK
	}
	for _, note := range res.Notes {
		fmt.Fprintln(a.Stdout, note)
	}
	if res.Written {
		fmt.Fprintln(a.Stdout, "next: mise run plan (review the plan, then mise run update)")
	}
	return ExitOK
}

func (a *App) plan(cfg *config.Config, opts *Options) ([]frontendPlan, error) {
	var active []config.Frontend
	for _, f := range cfg.Frontends {
		if f.ActiveFor(a.Platform) {
			active = append(active, f)
		}
	}
	if len(active) == 0 {
		return nil, fmt.Errorf("no active frontend for %s", a.Platform)
	}
	var override string
	if opts.Target != "" {
		if len(active) != 1 {
			return nil, fmt.Errorf("--target needs exactly one active frontend, found %d", len(active))
		}
		abs, err := filepath.Abs(opts.Target)
		if err != nil {
			return nil, fmt.Errorf("resolve --target %q: %w", opts.Target, err)
		}
		override = filepath.Clean(abs)
	}

	// Everything this run reads (workspace, configuration, layers, phrase
	// template) is a source. A target may not equal or contain any of them, nor
	// be contained by them, because distribution would overwrite inputs.
	reserved := []string{cfg.WorkPath(), cfg.Dir(), cfg.Path()}
	for _, layer := range []string{cfg.LocalLayerPath(), cfg.CommonUILayerPath(), cfg.PhraseExamplePath()} {
		if layer != "" {
			reserved = append(reserved, layer)
		}
	}
	for _, f := range cfg.Frontends {
		if layer := cfg.FrontendUILayer(f); layer != "" {
			reserved = append(reserved, layer)
		}
	}

	plans := make([]frontendPlan, 0, len(active))
	for _, f := range active {
		target := cfg.Target(f)
		if override != "" {
			target = override
		}
		if strings.TrimSpace(target) == "" {
			return nil, fmt.Errorf("frontend %s has no target directory", f.Name)
		}
		target = filepath.Clean(target)
		for _, prev := range plans {
			if config.PathsOverlap(target, prev.target) {
				return nil, fmt.Errorf("targets of %s and %s overlap: %s / %s", f.Name, prev.frontend.Name, target, prev.target)
			}
		}
		for _, source := range reserved {
			if config.PathsOverlap(target, source) {
				return nil, fmt.Errorf("target %s overlaps input path %s; refusing to write", target, source)
			}
		}
		plans = append(plans, frontendPlan{frontend: f, target: target})
	}
	return plans, nil
}

// preflight verifies inputs, targets, required programs and the cloud sync
// configuration before any side effect.
func (a *App) preflight(cfg *config.Config, plans []frontendPlan, opts *Options) error {
	var errs []error
	needDeploy := !opts.SyncOnly && !opts.NoRedeploy
	needSync := opts.SyncOnly || !opts.NoSync
	syncCapable := 0

	work := cfg.WorkPath()
	if !opts.SyncOnly {
		// Update inputs and every selected write target are validated as a
		// complete set before the update fetches or writes anything.
		for _, layer := range []struct {
			label string
			path  string
		}{
			{"local_layer", cfg.LocalLayerPath()},
			{"common_ui_layer", cfg.CommonUILayerPath()},
		} {
			if err := update.PreflightLayer(layer.path); err != nil {
				errs = append(errs, fmt.Errorf("%s: %w", layer.label, err))
			}
		}
		if p := cfg.PhraseExamplePath(); p != "" {
			if st, err := os.Stat(p); err != nil {
				errs = append(errs, fmt.Errorf("phrase_example %s: %w", p, err))
			} else if !st.Mode().IsRegular() {
				errs = append(errs, fmt.Errorf("phrase_example %s is not a regular file", p))
			}
		}
		for _, p := range plans {
			if err := update.PreflightLayer(cfg.FrontendUILayer(p.frontend)); err != nil {
				errs = append(errs, fmt.Errorf("ui_layer of %s: %w", p.frontend.Name, err))
			}
			if err := update.RejectSymlinkedPath(work, a.stageDir(cfg, p)); err != nil {
				errs = append(errs, err)
			}
			if err := update.PreflightTarget(p.target); err != nil {
				errs = append(errs, fmt.Errorf("frontend %s: %w", p.frontend.Name, err))
			}
		}
	}

	for _, p := range plans {
		completion := a.completion(p.frontend)
		runs := completion != config.CompletionNone && completion != ""
		if needDeploy && runs && p.frontend.Commands.Deploy != nil {
			exe := config.ExpandUser(p.frontend.Commands.Deploy.Executable)
			if _, err := exec.LookPath(exe); err != nil {
				errs = append(errs, fmt.Errorf("%s: deploy executable %s not found", p.frontend.Name, exe))
			}
		}
		if needSync && runs && p.frontend.Commands.Sync != nil {
			syncCapable++
			exe := config.ExpandUser(p.frontend.Commands.Sync.Executable)
			if _, err := exec.LookPath(exe); err != nil {
				errs = append(errs, fmt.Errorf("%s: sync executable %s not found", p.frontend.Name, exe))
			}
			if completion == config.CompletionState && !opts.DryRun {
				if _, err := rimesync.SnapshotDir(p.target); err != nil {
					errs = append(errs, fmt.Errorf("%s: cannot observe sync completion: %w", p.frontend.Name, err))
				}
			}
		}
	}
	if opts.SyncOnly && syncCapable == 0 {
		errs = append(errs, errors.New("--sync-only needs at least one desktop frontend that can sync"))
	}
	if opts.CloudSync {
		if cfg.CloudSync == nil {
			errs = append(errs, errors.New("--cloud-sync needs cloud_sync in the config"))
		} else {
			if syncCapable == 0 {
				errs = append(errs, errors.New("--cloud-sync needs at least one desktop frontend that can sync"))
			}
			if _, err := rimesync.UnisonPlan(a.unisonOptions(cfg)); err != nil {
				errs = append(errs, err)
			}
			if err := update.RejectSymlinkedPath(work, cfg.UnisonPath()); err != nil {
				errs = append(errs, err)
			}
			if !opts.DryRun {
				unison := config.ExpandUser(cfg.CloudSync.Unison)
				if strings.TrimSpace(unison) == "" {
					unison = "unison"
				}
				if _, err := exec.LookPath(unison); err != nil {
					errs = append(errs, fmt.Errorf("unison executable %q not found", unison))
				}
			}
		}
	}
	return errors.Join(errs...)
}

func (a *App) runUpdate(ctx context.Context, cfg *config.Config, plans []frontendPlan, opts *Options) int {
	work := cfg.WorkPath()
	client := update.NewClient(cfg.GitHubAPIBase, a.getenv("GITHUB_TOKEN"))
	layout, statuses, err := update.Ensure(ctx, update.FetchOptions{
		WorkDir:    work,
		Client:     client,
		NoDownload: opts.NoDownload,
		Log:        a.Stderr,
	})
	if err != nil {
		return a.fail("update upstream resources", err)
	}
	for _, st := range statuses {
		fmt.Fprintf(a.Stderr, "resource %-5s %-10s %s\n", st.Resource, st.Action, st.Version)
	}

	for _, p := range plans {
		if err := ctx.Err(); err != nil {
			return a.fail("cancelled", err)
		}
		stage, err := update.BuildStage(ctx, update.StageOptions{
			Layout:         layout,
			LocalLayer:     cfg.LocalLayerPath(),
			CommonLayer:    cfg.CommonUILayerPath(),
			UILayer:        cfg.FrontendUILayer(p.frontend),
			StageDir:       a.stageDir(cfg, p),
			WorkDir:        work,
			TargetDir:      p.target,
			UserPhraseFile: cfg.UserPhraseFile,
			PhraseExample:  cfg.PhraseExamplePath(),
		})
		if err != nil {
			return a.fail("stage "+p.frontend.Name, err)
		}
		protect := update.Protect{Exclude: p.frontend.Exclude}
		if !stage.PhraseManaged {
			protect.PhraseFile = cfg.UserPhraseFile
		}
		res, err := update.SyncTarget(ctx, update.SyncOptions{
			Stage:     stage,
			TargetDir: p.target,
			Protect:   protect,
			Delete:    opts.Delete,
			DryRun:    opts.DryRun,
			Out:       a.Stdout,
		})
		if err != nil {
			return a.fail("distribute to "+p.frontend.Name, err)
		}
		verb := "wrote"
		if opts.DryRun {
			verb = "would write"
		}
		fmt.Fprintf(a.Stderr, "%s: %s %s %d (%d replaced existing), unchanged %d, kept %d, deleted %d\n",
			p.frontend.Name, p.target, verb, len(res.Copied), len(res.Updated), len(res.Skipped), len(res.Kept), len(res.Deleted))
	}

	return a.runNativeSteps(ctx, cfg, plans, opts)
}

// runNativeSteps performs deploy, the optional cloud sync and the Rime sync in
// the documented order. On any failure the remaining steps, including the
// final Unison run, are not attempted.
func (a *App) runNativeSteps(ctx context.Context, cfg *config.Config, plans []frontendPlan, opts *Options) int {
	if opts.DryRun {
		a.printNativePlan(cfg, plans, opts)
		return ExitOK
	}
	runner := &rimesync.Runner{
		Err:    a.Stderr,
		Wait:   time.Duration(cfg.SyncWaitSeconds) * time.Second,
		Settle: a.Settle,
		Now:    a.Now,
	}

	if !opts.SyncOnly && !opts.NoRedeploy {
		for _, p := range plans {
			cmd := a.deployCommand(p)
			if cmd == nil {
				continue
			}
			res, err := runner.Run(ctx, p.frontend.Name+"/deploy", *cmd)
			if err != nil {
				return a.fail(p.frontend.Name+" deploy", err)
			}
			fmt.Fprintf(a.Stderr, "%s: deploy finished in %s (%s)\n", p.frontend.Name, res.Elapsed.Round(time.Second), res.Detail)
		}
	}

	if opts.CloudSync {
		fmt.Fprintln(a.Stderr, "cloud sync: unison OneDrive <-> iCloud before the Rime sync")
		if err := a.runUnison(ctx, cfg); err != nil {
			return a.fail("cloud sync before the Rime sync", err)
		}
	}

	if !opts.NoSync {
		if err := a.syncAll(ctx, runner, plans, opts.SyncOnly); err != nil {
			// A submitted but unobserved sync must not be reported as a
			// finished chain, and the final Unison run stays skipped.
			return a.fail("Rime user dictionary sync", err)
		}
	}

	if opts.CloudSync {
		fmt.Fprintln(a.Stderr, "cloud sync: unison OneDrive <-> iCloud after the Rime sync")
		if err := a.runUnison(ctx, cfg); err != nil {
			return a.fail("cloud sync after the Rime sync", err)
		}
		fmt.Fprintln(a.Stderr, "cloud sync: local folders are in sync; OneDrive/iCloud clients still upload them, and other devices import on their next sync")
	}
	return ExitOK
}

func (a *App) syncAll(ctx context.Context, runner *rimesync.Runner, plans []frontendPlan, require bool) error {
	synced := 0
	for _, p := range plans {
		cmd := a.syncCommand(p)
		if cmd == nil {
			fmt.Fprintf(a.Stderr, "%s: synced by the device app; no desktop sync step\n", p.frontend.Name)
			continue
		}
		res, err := runner.Run(ctx, p.frontend.Name+"/sync", *cmd)
		if err != nil {
			return err
		}
		synced++
		fmt.Fprintf(a.Stderr, "%s: sync finished in %s (%s)\n", p.frontend.Name, res.Elapsed.Round(time.Second), res.Detail)
	}
	if synced == 0 {
		if require {
			return errors.New("no frontend can sync")
		}
		fmt.Fprintln(a.Stderr, "no desktop frontend to sync; only files were updated (devices sync themselves)")
	}
	return nil
}

// printNativePlan prints the native steps in execution order.
func (a *App) printNativePlan(cfg *config.Config, plans []frontendPlan, opts *Options) {
	if !opts.SyncOnly && !opts.NoRedeploy {
		for _, p := range plans {
			if cmd := a.deployCommand(p); cmd != nil {
				printCommand(a.Stdout, p.frontend.Name+"/deploy", *cmd)
				if p.frontend.Kind == config.KindWeasel {
					fmt.Fprintln(a.Stdout, "note   Weasel deploy results cannot be verified and count as failure; use --no-redeploy to update files only")
				}
			}
		}
	}
	unison := ""
	if opts.CloudSync {
		if line, err := rimesync.UnisonPlan(a.unisonOptions(cfg)); err == nil {
			unison = line
		}
		fmt.Fprintf(a.Stdout, "run    cloud sync (before Rime sync): %s\n", unison)
	}
	if !opts.NoSync {
		for _, p := range plans {
			if cmd := a.syncCommand(p); cmd != nil {
				printCommand(a.Stdout, p.frontend.Name+"/sync", *cmd)
			} else {
				fmt.Fprintf(a.Stdout, "skip   %s/sync (synced by the device app)\n", p.frontend.Name)
			}
		}
	}
	if opts.CloudSync {
		fmt.Fprintf(a.Stdout, "run    cloud sync (after Rime sync): %s\n", unison)
	}
}

func printCommand(w io.Writer, label string, cmd rimesync.Command) {
	fmt.Fprintf(w, "run    %s: %s %s (completion: %s)\n", label, cmd.Executable, strings.Join(cmd.Args, " "), cmd.Completion)
}

func (a *App) completion(f config.Frontend) string {
	c := strings.TrimSpace(f.SyncCompletion)
	if c == "" {
		if kind, ok := config.Kinds[f.Kind]; ok {
			c = kind.DefaultCompletion
		}
	}
	return c
}

func (a *App) syncCommand(p frontendPlan) *rimesync.Command {
	return a.buildCommand(p, p.frontend.Commands.Sync, "sync")
}

func (a *App) deployCommand(p frontendPlan) *rimesync.Command {
	return a.buildCommand(p, p.frontend.Commands.Deploy, "deploy")
}

func (a *App) buildCommand(p frontendPlan, cmd *config.Command, mode string) *rimesync.Command {
	f := p.frontend
	completion := a.completion(f)
	if cmd == nil || completion == "" || completion == config.CompletionNone {
		return nil
	}
	// Weasel's WeaselDeployer /deploy ignores the task results and returns
	// zero even when deployment failed. Never report that as success.
	if mode == "deploy" && f.Kind == config.KindWeasel {
		completion = "unverifiable"
	}
	return &rimesync.Command{
		Executable: config.ExpandUser(cmd.Executable),
		Args:       cmd.Args,
		Completion: completion,
		Mode:       mode,
		LogDir:     config.SyncLogDirectory(f),
		UserDir:    p.target,
	}
}

func (a *App) unisonOptions(cfg *config.Config) rimesync.UnisonOptions {
	o := rimesync.UnisonOptions{Out: a.Stderr, Err: a.Stderr, ArchiveDir: cfg.UnisonPath()}
	if cfg.CloudSync != nil {
		o.Unison = config.ExpandUser(cfg.CloudSync.Unison)
		o.OneDriveDir = cfg.Resolve(cfg.CloudSync.OneDriveDir)
		o.ICloudDir = cfg.Resolve(cfg.CloudSync.ICloudDir)
	}
	return o
}

func (a *App) runUnison(ctx context.Context, cfg *config.Config) error {
	if cfg.CloudSync == nil {
		return errors.New("missing cloud_sync config")
	}
	return rimesync.RunUnison(ctx, a.unisonOptions(cfg))
}

func (a *App) fail(what string, err error) int {
	fmt.Fprintf(a.Stderr, "error: %s: %v\n", what, err)
	return ExitFailure
}

func (a *App) getenv(key string) string {
	if a.Getenv == nil {
		return ""
	}
	return a.Getenv(key)
}

func (a *App) stageDir(cfg *config.Config, p frontendPlan) string {
	return filepath.Join(cfg.WorkPath(), "stage", stageName(p.frontend.Name))
}

func stageName(name string) string {
	var b strings.Builder
	for _, r := range name {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_':
			b.WriteRune(r)
		default:
			b.WriteByte('_')
		}
	}
	if b.Len() == 0 {
		return "frontend"
	}
	return b.String()
}
