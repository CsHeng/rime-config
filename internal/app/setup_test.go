package app

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"rime-config/internal/config"
)

func setupTestApp(t *testing.T) (*App, *bytes.Buffer, *bytes.Buffer) {
	t.Helper()
	var out, errOut bytes.Buffer
	return &App{
		Stdout:   &out,
		Stderr:   &errOut,
		Platform: "darwin",
		Getenv:   func(string) string { return "" },
	}, &out, &errOut
}

func installFakeSquirrel(t *testing.T, home string) {
	t.Helper()
	app := filepath.Join(home, "Library", "Input Methods", "Squirrel.app")
	if err := os.MkdirAll(filepath.Join(app, "Contents", "MacOS"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(app, "Contents", "MacOS", "Squirrel"), []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
}

func TestSetupWritesDetectedConfig(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	installFakeSquirrel(t, home)
	cfgPath := filepath.Join(t.TempDir(), "frontends.json")

	a, _, errOut := setupTestApp(t)
	if code := a.Run(context.Background(), []string{"--setup", "--config", cfgPath}); code != ExitOK {
		t.Fatalf("exit = %d, stderr = %s", code, errOut.String())
	}
	cfg, err := config.Load(cfgPath)
	if err != nil {
		t.Fatalf("written config is invalid: %v", err)
	}
	if len(cfg.Frontends) != 1 || cfg.Frontends[0].Kind != config.KindSquirrel {
		t.Fatalf("unexpected frontends: %+v", cfg.Frontends)
	}
	entries, _ := os.ReadDir(filepath.Dir(cfgPath))
	if len(entries) != 1 {
		t.Fatalf("setup must leave only frontends.json next to the config, found %d entries", len(entries))
	}
}

func TestSetupDryRunPrintsJSONAndWritesNothing(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	installFakeSquirrel(t, home)
	cfgPath := filepath.Join(t.TempDir(), "frontends.json")

	a, out, errOut := setupTestApp(t)
	if code := a.Run(context.Background(), []string{"--setup", "--dry-run", "--config", cfgPath}); code != ExitOK {
		t.Fatalf("exit = %d, stderr = %s", code, errOut.String())
	}
	if _, err := os.Stat(cfgPath); !os.IsNotExist(err) {
		t.Fatalf("dry-run wrote the config: %v", err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(out.Bytes(), &decoded); err != nil {
		t.Fatalf("stdout is not JSON: %v\n%s", err, out.String())
	}
	if _, ok := decoded["frontends"]; !ok {
		t.Errorf("stdout JSON lacks frontends: %s", out.String())
	}
}

type failingWriter struct{}

func (failingWriter) Write([]byte) (int, error) { return 0, errors.New("disk full") }

func TestSetupDryRunFailsWhenOutputCannotBeWritten(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	installFakeSquirrel(t, home)
	a, _, errOut := setupTestApp(t)
	a.Stdout = failingWriter{}
	code := a.Run(context.Background(), []string{"--setup", "--dry-run", "--config", filepath.Join(t.TempDir(), "frontends.json")})
	if code != ExitFailure {
		t.Fatalf("exit = %d, want %d when the generated JSON cannot be written", code, ExitFailure)
	}
	if !strings.Contains(errOut.String(), "disk full") {
		t.Fatalf("stderr must carry the write error: %q", errOut.String())
	}
}

func TestSetupKeepsExistingConfigWithoutForce(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	installFakeSquirrel(t, home)
	cfgPath := filepath.Join(t.TempDir(), "frontends.json")
	const original = `{"keep": true}`
	if err := os.WriteFile(cfgPath, []byte(original), 0o644); err != nil {
		t.Fatal(err)
	}

	a, _, errOut := setupTestApp(t)
	if code := a.Run(context.Background(), []string{"--setup", "--config", cfgPath}); code != ExitOK {
		t.Fatalf("exit = %d, stderr = %s", code, errOut.String())
	}
	if data, _ := os.ReadFile(cfgPath); string(data) != original {
		t.Fatalf("config rewritten without --force: %s", data)
	}
}

func TestSetupOptionCombinations(t *testing.T) {
	for _, args := range [][]string{
		{"--setup", "--sync-only"},
		{"--setup", "--no-download"},
		{"--setup", "--delete"},
		{"--setup", "--target", "/tmp/x"},
	} {
		o, _, err := ParseArgs(args)
		if err != nil {
			t.Fatalf("ParseArgs(%v): %v", args, err)
		}
		if err := o.Validate("darwin"); err == nil {
			t.Errorf("%v must be rejected", args)
		}
	}
	o, _, err := ParseArgs([]string{"--force"})
	if err != nil {
		t.Fatal(err)
	}
	if err := o.Validate("darwin"); err == nil {
		t.Error("--force without --setup must be rejected")
	}
	o, _, err = ParseArgs([]string{"--setup", "--force", "--dry-run", "--config", "x.json"})
	if err != nil {
		t.Fatal(err)
	}
	if err := o.Validate("darwin"); err != nil {
		t.Errorf("a valid setup combination was rejected: %v", err)
	}
}

func TestBuildCommandExpandsHome(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home directory")
	}
	a := &App{Platform: "darwin"}
	p := frontendPlan{
		frontend: config.Frontend{
			Kind: config.KindSquirrel,
			Commands: config.Commands{
				Sync: &config.Command{Executable: "~/bin/squirrel", Args: []string{"--sync"}},
			},
		},
		target: filepath.Join(home, "Library", "Rime"),
	}
	cmd := a.syncCommand(p)
	if cmd == nil {
		t.Fatal("syncCommand must not be nil")
	}
	if want := filepath.Join(home, "bin", "squirrel"); cmd.Executable != want {
		t.Fatalf("Executable = %q, want %q", cmd.Executable, want)
	}
	if cmd.Completion != config.CompletionState || cmd.UserDir != p.target {
		t.Fatalf("Squirrel sync must observe the target state: %+v", cmd)
	}
}
