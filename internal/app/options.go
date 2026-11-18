// Package app wires configuration, upstream updates, distribution and Rime
// synchronization into the rime-config command line.
package app

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"strings"
)

// Exit codes.
const (
	ExitOK      = 0
	ExitFailure = 1
	ExitUsage   = 2
)

// Options are the parsed command line options.
type Options struct {
	ConfigPath  string
	Setup       bool
	Force       bool
	SyncOnly    bool
	NoSync      bool
	NoDownload  bool
	NoRedeploy  bool
	Delete      bool
	DryRun      bool
	CloudSync   bool
	Target      string
	ShowVersion bool
}

// Usage is the help text of the command.
func Usage() string {
	return `usage: rime-config [options]

Update Wanxiang Rime resources, compose the layered configuration, distribute
it to the selected Rime frontends, then deploy and sync user dictionaries.

options:
  --config PATH     config file (default <executable dir>/config/frontends.json)
  --setup           detect Squirrel/Weasel/Hamster3 and cloud sync folders, write the config
  --force           with --setup: rebuild an existing config (a backup is kept)
  --sync-only       only sync Rime user dictionaries; no download, staging or deploy
  --no-sync         skip the Rime user dictionary sync after an update
  --no-download     never touch the network; use the existing cache/upstream only
  --no-redeploy     skip the native deploy after an update (files only)
  --delete          delete target files this tool no longer distributes (protected files stay)
  --dry-run         print the plan; write no target and run no Rime/Unison command
  --cloud-sync      macOS: run Unison between the OneDrive and iCloud sync folders
                    before and after the Rime sync
  --target PATH     redirect the single active frontend to PATH (sandbox distribution only)
  --version         print the version and exit
  -h, --help        print this help
`
}

// ParseArgs parses the command line. The returned usage text is printed by the
// caller on error. A help request returns flag.ErrHelp.
func ParseArgs(args []string) (*Options, string, error) {
	o := &Options{}
	fs := flag.NewFlagSet("rime-config", flag.ContinueOnError)
	var buf bytes.Buffer
	fs.SetOutput(&buf)
	fs.Usage = func() {}

	fs.StringVar(&o.ConfigPath, "config", "", "config file")
	fs.BoolVar(&o.Setup, "setup", false, "detect frontends and write the config")
	fs.BoolVar(&o.Force, "force", false, "rebuild an existing config")
	fs.BoolVar(&o.SyncOnly, "sync-only", false, "only run the Rime sync")
	fs.BoolVar(&o.NoSync, "no-sync", false, "skip the Rime sync")
	fs.BoolVar(&o.NoDownload, "no-download", false, "no network access")
	fs.BoolVar(&o.NoRedeploy, "no-redeploy", false, "skip the deploy")
	fs.BoolVar(&o.Delete, "delete", false, "delete files no longer distributed")
	fs.BoolVar(&o.DryRun, "dry-run", false, "print the plan only")
	fs.BoolVar(&o.CloudSync, "cloud-sync", false, "macOS OneDrive/iCloud Unison sync")
	fs.StringVar(&o.Target, "target", "", "redirect the single active frontend")
	fs.BoolVar(&o.ShowVersion, "version", false, "print the version")

	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil, Usage(), err
		}
		msg := strings.TrimSpace(buf.String())
		if msg == "" {
			msg = err.Error()
		}
		return nil, Usage(), errors.New(msg)
	}
	if fs.NArg() > 0 {
		return nil, Usage(), fmt.Errorf("unexpected arguments: %s", strings.Join(fs.Args(), " "))
	}
	return o, Usage(), nil
}

// Validate checks option combinations that are meaningless or contradictory.
// It runs before any side effect.
func (o *Options) Validate(platform string) error {
	var errs []error
	if o.Setup {
		var bad []string
		if o.SyncOnly {
			bad = append(bad, "--sync-only")
		}
		if o.NoSync {
			bad = append(bad, "--no-sync")
		}
		if o.NoDownload {
			bad = append(bad, "--no-download")
		}
		if o.NoRedeploy {
			bad = append(bad, "--no-redeploy")
		}
		if o.Delete {
			bad = append(bad, "--delete")
		}
		if o.CloudSync {
			bad = append(bad, "--cloud-sync")
		}
		if o.Target != "" {
			bad = append(bad, "--target")
		}
		if len(bad) > 0 {
			errs = append(errs, fmt.Errorf("--setup cannot be combined with %s", strings.Join(bad, ", ")))
		}
		return errors.Join(errs...)
	}
	if o.Force {
		errs = append(errs, errors.New("--force requires --setup"))
	}
	if o.SyncOnly {
		var bad []string
		if o.NoSync {
			bad = append(bad, "--no-sync")
		}
		if o.NoDownload {
			bad = append(bad, "--no-download")
		}
		if o.NoRedeploy {
			bad = append(bad, "--no-redeploy")
		}
		if o.Delete {
			bad = append(bad, "--delete")
		}
		if o.Target != "" {
			bad = append(bad, "--target")
		}
		if len(bad) > 0 {
			errs = append(errs, fmt.Errorf("--sync-only cannot be combined with %s", strings.Join(bad, ", ")))
		}
	}
	if o.Target != "" && !o.DryRun && (!o.NoRedeploy || !o.NoSync) {
		errs = append(errs, errors.New("--target only redirects file distribution: without --dry-run it needs --no-redeploy and --no-sync"))
	}
	if o.CloudSync {
		if platform != "darwin" {
			errs = append(errs, fmt.Errorf("--cloud-sync is only supported on macOS (current platform %s)", platform))
		}
		if o.NoSync {
			errs = append(errs, errors.New("--cloud-sync needs the Rime sync and cannot be combined with --no-sync"))
		}
	}
	return errors.Join(errs...)
}
