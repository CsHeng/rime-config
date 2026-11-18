package rimesync

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// UnisonOptions configures the macOS Unison sync between the local OneDrive
// Rime sync folder and the iCloud folder used by iOS frontends.
type UnisonOptions struct {
	Unison      string
	OneDriveDir string
	ICloudDir   string
	// ArchiveDir is the Unison state directory (UNISON). The tool owns it, so
	// Unison neither shares archives with other uses nor reads the user's
	// default profile.
	ArchiveDir string
	DryRun     bool
	Out        io.Writer
	Err        io.Writer
}

// UnisonArgs are the Unison arguments: keep modification times, ignore
// permission differences, prefer the newer copy on conflicts and ignore
// temporary files. Unison keeps its own archive for change detection.
func UnisonArgs(oneDriveDir, iCloudDir string) []string {
	return []string{
		oneDriveDir,
		iCloudDir,
		"-auto",
		"-batch",
		"-prefer", "newer",
		"-times",
		"-perms", "0",
		"-ignore", "Name .DS_Store",
		"-ignore", "Name *.tmp",
	}
}

func unisonExecutable(o UnisonOptions) string {
	if strings.TrimSpace(o.Unison) == "" {
		return "unison"
	}
	return o.Unison
}

// UnisonPlan returns the human readable plan line for a dry run.
func UnisonPlan(o UnisonOptions) (string, error) {
	if err := validateUnisonDirs(o); err != nil {
		return "", err
	}
	return fmt.Sprintf("UNISON=%s %s %s", o.ArchiveDir, unisonExecutable(o), strings.Join(UnisonArgs(o.OneDriveDir, o.ICloudDir), " ")), nil
}

// RunUnison syncs the OneDrive and iCloud folders once in both directions.
func RunUnison(ctx context.Context, o UnisonOptions) error {
	if err := validateUnisonDirs(o); err != nil {
		return err
	}
	if o.DryRun {
		line, err := UnisonPlan(o)
		if err != nil {
			return err
		}
		if o.Out != nil {
			fmt.Fprintln(o.Out, line)
		}
		return nil
	}
	exe, err := exec.LookPath(unisonExecutable(o))
	if err != nil {
		return fmt.Errorf("unison executable %q not found: %w", unisonExecutable(o), err)
	}
	if strings.TrimSpace(o.ArchiveDir) == "" {
		return errors.New("missing Unison archive directory")
	}
	if err := os.MkdirAll(o.ArchiveDir, 0o755); err != nil {
		return fmt.Errorf("create Unison archive directory: %w", err)
	}
	cmd := exec.CommandContext(ctx, exe, UnisonArgs(o.OneDriveDir, o.ICloudDir)...)
	cmd.Stdout = o.Out
	cmd.Stderr = o.Err
	cmd.Env = append(withoutEnv(os.Environ(), "UNISON"), "UNISON="+o.ArchiveDir)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("unison %s <-> %s failed: %w", o.OneDriveDir, o.ICloudDir, err)
	}
	return nil
}

func withoutEnv(env []string, key string) []string {
	out := env[:0:0]
	for _, kv := range env {
		if strings.HasPrefix(kv, key+"=") {
			continue
		}
		out = append(out, kv)
	}
	return out
}

func validateUnisonDirs(o UnisonOptions) error {
	if strings.TrimSpace(o.OneDriveDir) == "" {
		return errors.New("cloud sync: missing OneDrive directory")
	}
	if strings.TrimSpace(o.ICloudDir) == "" {
		return errors.New("cloud sync: missing iCloud directory")
	}
	if !filepath.IsAbs(o.OneDriveDir) || !filepath.IsAbs(o.ICloudDir) {
		return errors.New("cloud sync: directories must be absolute paths")
	}
	one := filepath.Clean(o.OneDriveDir)
	cloud := filepath.Clean(o.ICloudDir)
	if one == cloud {
		return errors.New("cloud sync: OneDrive and iCloud directories are the same")
	}
	if inside(one, cloud) || inside(cloud, one) {
		return fmt.Errorf("cloud sync: directories must not contain each other: %s / %s", one, cloud)
	}
	for _, dir := range []string{one, cloud} {
		st, err := os.Stat(dir)
		if err != nil {
			return fmt.Errorf("cloud sync: directory unavailable %s: %w", dir, err)
		}
		if !st.IsDir() {
			return fmt.Errorf("cloud sync: not a directory: %s", dir)
		}
	}
	return nil
}

func inside(child, parent string) bool {
	rel, err := filepath.Rel(parent, child)
	if err != nil {
		return false
	}
	return rel != "." && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}
