package setup

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"rime-config/internal/config"
)

func writeTestFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func makeSquirrel(t *testing.T, home string) string {
	t.Helper()
	app := filepath.Join(home, "Library", "Input Methods", "Squirrel.app")
	writeTestFile(t, filepath.Join(app, "Contents", "MacOS", "Squirrel"), "#!/bin/sh\n")
	return app
}

func makeSyncTree(t *testing.T, root, installation string) {
	t.Helper()
	writeTestFile(t, filepath.Join(root, installation, "wanxiang.userdb.txt"), "snapshot")
}

func TestRunDetectsSquirrelAndCloud(t *testing.T) {
	home := t.TempDir()
	app := makeSquirrel(t, home)
	makeSyncTree(t, filepath.Join(home, "Library", "Mobile Documents", "com~apple~CloudDocs", "RimeUserSync"), "Squirrel-CsHeng's-Mac")
	makeSyncTree(t, filepath.Join(home, "Library", "CloudStorage", "OneDrive-Personal", "Apps", "RimeSync"), "Weasel-CsHeng's-PC")
	cfgPath := filepath.Join(t.TempDir(), "frontends.json")

	res, err := Run(Options{
		Home:         home,
		Platform:     "darwin",
		ConfigPath:   cfgPath,
		SquirrelApps: []string{app},
		Getenv:       func(string) string { return "" },
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Written {
		t.Fatalf("config not written: %v", res.Notes)
	}

	data, err := os.ReadFile(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	for _, want := range []string{
		`"target_dir": "~/Library/Rime"`,
		`"one_drive_dir": "~/Library/CloudStorage/OneDrive-Personal/Apps/RimeSync"`,
		`"i_cloud_dir": "~/Library/Mobile Documents/com~apple~CloudDocs/RimeUserSync"`,
		`"executable": "~/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel"`,
	} {
		if !strings.Contains(text, want) {
			t.Errorf("generated config lacks %s:\n%s", want, text)
		}
	}
	if strings.Contains(text, home) {
		t.Errorf("generated config contains the real home %s:\n%s", home, text)
	}

	cfg, err := config.Load(cfgPath)
	if err != nil {
		t.Fatalf("generated config does not load: %v", err)
	}
	if len(cfg.Frontends) != 1 || cfg.Frontends[0].Kind != config.KindSquirrel {
		t.Fatalf("unexpected frontends: %+v", cfg.Frontends)
	}
	if cfg.Frontends[0].SyncCompletion != config.CompletionState {
		t.Errorf("Squirrel default completion = %q, want state", cfg.Frontends[0].SyncCompletion)
	}
	if cfg.CloudSync == nil || cfg.CloudSync.Unison != "unison" {
		t.Errorf("unexpected cloud_sync defaults: %+v", cfg.CloudSync)
	}
}

func TestRunPrefersAppsRimeSyncOverOneDriveRoot(t *testing.T) {
	home := t.TempDir()
	app := makeSquirrel(t, home)
	oneDrive := filepath.Join(home, "Library", "CloudStorage", "OneDrive-Personal")
	makeSyncTree(t, oneDrive, "Some-Installation")
	makeSyncTree(t, filepath.Join(oneDrive, "Apps", "RimeSync"), "Weasel-PC")
	makeSyncTree(t, filepath.Join(home, "Library", "Mobile Documents", "com~apple~CloudDocs", "RimeUserSync"), "Squirrel-Mac")
	cfgPath := filepath.Join(t.TempDir(), "frontends.json")

	_, err := Run(Options{
		Home:         home,
		Platform:     "darwin",
		ConfigPath:   cfgPath,
		SquirrelApps: []string{app},
		Getenv:       func(string) string { return "" },
	})
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Load(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.CloudSync == nil || !strings.HasSuffix(cfg.CloudSync.OneDriveDir, "Apps/RimeSync") {
		t.Fatalf("Apps/RimeSync must win, got %+v", cfg.CloudSync)
	}
}

func TestRunWithoutCloudWritesNoCloudSync(t *testing.T) {
	home := t.TempDir()
	app := makeSquirrel(t, home)
	cfgPath := filepath.Join(t.TempDir(), "frontends.json")

	if _, err := Run(Options{
		Home:         home,
		Platform:     "darwin",
		ConfigPath:   cfgPath,
		SquirrelApps: []string{app},
		Getenv:       func(string) string { return "" },
	}); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Load(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.CloudSync != nil {
		t.Fatalf("cloud_sync must be omitted without detected folders: %+v", cfg.CloudSync)
	}
}

func TestRunLeavesExistingConfigUnlessForced(t *testing.T) {
	home := t.TempDir()
	app := makeSquirrel(t, home)
	cfgPath := filepath.Join(t.TempDir(), "frontends.json")
	const original = `{"marker": true}`
	writeTestFile(t, cfgPath, original)

	res, err := Run(Options{
		Home:         home,
		Platform:     "darwin",
		ConfigPath:   cfgPath,
		SquirrelApps: []string{app},
		Getenv:       func(string) string { return "" },
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Written {
		t.Fatal("an existing config must not be replaced without --force")
	}
	data, _ := os.ReadFile(cfgPath)
	if string(data) != original {
		t.Fatalf("existing config was rewritten: %s", data)
	}
	if !notesContain(res.Notes, "--force") {
		t.Errorf("the notes must mention --force: %v", res.Notes)
	}

	res, err = Run(Options{
		Home:         home,
		Platform:     "darwin",
		ConfigPath:   cfgPath,
		Force:        true,
		SquirrelApps: []string{app},
		Getenv:       func(string) string { return "" },
	})
	if err != nil {
		t.Fatal(err)
	}
	if !res.Written {
		t.Fatal("--force must rebuild the config")
	}
	cfg, err := config.Load(cfgPath)
	if err != nil {
		t.Fatalf("rebuilt config is invalid: %v", err)
	}
	if len(cfg.Frontends) != 1 {
		t.Fatalf("rebuilt frontend count = %d", len(cfg.Frontends))
	}
	if backup, err := os.ReadFile(cfgPath + ".bak"); err != nil || string(backup) != original {
		t.Fatalf("--force must keep the previous config as .bak: %q %v", backup, err)
	}
}

func TestRunDryRunWritesNothing(t *testing.T) {
	home := t.TempDir()
	app := makeSquirrel(t, home)
	cfgPath := filepath.Join(t.TempDir(), "frontends.json")

	res, err := Run(Options{
		Home:         home,
		Platform:     "darwin",
		ConfigPath:   cfgPath,
		DryRun:       true,
		SquirrelApps: []string{app},
		Getenv:       func(string) string { return "" },
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Written {
		t.Fatal("dry-run must not write")
	}
	if _, err := os.Stat(cfgPath); !os.IsNotExist(err) {
		t.Fatalf("config exists after dry-run: %v", err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(res.ConfigJSON, &decoded); err != nil {
		t.Fatalf("dry-run JSON invalid: %v", err)
	}
}

func TestRunDetectsWeasel(t *testing.T) {
	home := t.TempDir()
	root := t.TempDir()
	exe := filepath.Join(root, "weasel-0.17.4", "WeaselDeployer.exe")
	writeTestFile(t, exe, "binary")
	newer := filepath.Join(root, "weasel-0.17.10", "WeaselDeployer.exe")
	writeTestFile(t, newer, "binary")
	cfgPath := filepath.Join(t.TempDir(), "frontends.json")

	res, err := Run(Options{
		Home:         home,
		Platform:     "windows",
		ConfigPath:   cfgPath,
		ProgramRoots: []string{root},
		Getenv:       func(string) string { return "" },
	})
	if err != nil {
		t.Fatal(err)
	}
	if !res.Written {
		t.Fatalf("config not written: %v", res.Notes)
	}
	text, _ := os.ReadFile(cfgPath)
	for _, want := range []string{`"kind": "weasel"`, `"target_dir": "~/AppData/Roaming/Rime"`, `"args": [`, `"/deploy"`, `weasel-0.17.10`} {
		if !strings.Contains(string(text), want) {
			t.Errorf("config lacks %s:\n%s", want, text)
		}
	}
	if strings.Contains(string(text), `"sync_completion": "process"`) {
		t.Error("Weasel must not use process completion")
	}
}

func TestRunDetectsHamster3(t *testing.T) {
	home := t.TempDir()
	app := makeSquirrel(t, home)
	container := filepath.Join(home, "Library", "Mobile Documents", "iCloud~com~ihsiao~apps~Hamster3", "Documents", "RimeUserData")
	writeTestFile(t, filepath.Join(container, "other", "default.yaml"), "schema_list: []\n")
	writeTestFile(t, filepath.Join(container, "rime-wanxiang", "wanxiang.schema.yaml"), "schema: {}\n")
	cfgPath := filepath.Join(t.TempDir(), "frontends.json")

	_, err := Run(Options{
		Home:         home,
		Platform:     "darwin",
		ConfigPath:   cfgPath,
		SquirrelApps: []string{app},
		Getenv:       func(string) string { return "" },
	})
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Load(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, f := range cfg.Frontends {
		if f.Kind == config.KindHamster3 {
			found = true
			if want := "~/Library/Mobile Documents/iCloud~com~ihsiao~apps~Hamster3/Documents/RimeUserData/rime-wanxiang"; f.TargetDir != want {
				t.Errorf("Hamster3 target = %s, want %s", f.TargetDir, want)
			}
			if f.UILayer != "frontends/hamster3" {
				t.Errorf("Hamster3 must use its UI layer with the return rule, got %q", f.UILayer)
			}
		}
	}
	if !found {
		t.Fatalf("Hamster3 not detected: %+v", cfg.Frontends)
	}
}

func TestRunDeduplicatesOneDriveAlias(t *testing.T) {
	home := t.TempDir()
	app := makeSquirrel(t, home)
	oneDrive := filepath.Join(home, "Library", "CloudStorage", "OneDrive-Personal")
	makeSyncTree(t, filepath.Join(oneDrive, "Apps", "RimeSync"), "Weasel-PC")
	makeSyncTree(t, filepath.Join(home, "Library", "Mobile Documents", "com~apple~CloudDocs", "RimeUserSync"), "Squirrel-Mac")
	if err := os.Symlink(oneDrive, filepath.Join(home, "OneDrive")); err != nil {
		t.Skipf("cannot create symlink: %v", err)
	}
	cfgPath := filepath.Join(t.TempDir(), "frontends.json")

	res, err := Run(Options{
		Home:         home,
		Platform:     "darwin",
		ConfigPath:   cfgPath,
		SquirrelApps: []string{app},
		Getenv:       func(string) string { return "" },
	})
	if err != nil {
		t.Fatal(err)
	}
	if notesContain(res.Notes, "OneDrive sync folders") {
		t.Errorf("a symlink alias was counted as another candidate: %v", res.Notes)
	}
	cfg, err := config.Load(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.CloudSync == nil || !strings.Contains(cfg.CloudSync.OneDriveDir, "Library/CloudStorage/OneDrive-Personal/Apps/RimeSync") {
		t.Fatalf("the CloudStorage path must win, got %+v", cfg.CloudSync)
	}
}

func TestRunFailsWithoutFrontend(t *testing.T) {
	home := t.TempDir()
	cfgPath := filepath.Join(t.TempDir(), "frontends.json")
	_, err := Run(Options{
		Home:         home,
		Platform:     "darwin",
		ConfigPath:   cfgPath,
		SquirrelApps: []string{filepath.Join(home, "missing.app")},
		Getenv:       func(string) string { return "" },
	})
	if err == nil {
		t.Fatal("no frontend must be an error")
	}
	if _, statErr := os.Stat(cfgPath); !os.IsNotExist(statErr) {
		t.Fatal("a failure must not write the config")
	}
}

func notesContain(notes []string, want string) bool {
	for _, n := range notes {
		if strings.Contains(n, want) {
			return true
		}
	}
	return false
}
