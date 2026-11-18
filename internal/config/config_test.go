package config

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func writeConfig(t *testing.T, dir, body string) string {
	t.Helper()
	p := filepath.Join(dir, "frontends.json")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatalf("write test config: %v", err)
	}
	return p
}

func baseJSON(extra string) string {
	return `{
  "work_dir": "../build",
  "local_layer": "local",
  "common_ui_layer": "common",
  "phrase_example": "common/custom_phrase_user.dict.yaml",
  "frontends": [
    {"name": "squirrel", "kind": "squirrel", "active": "auto", "target_dir": "~/Library/Rime", "ui_layer": "frontends/squirrel", "exclude": ["*.log"]}
  ]` + extra + `
}`
}

func TestLoadDefaultsAndPaths(t *testing.T) {
	dir := t.TempDir()
	cfgDir := filepath.Join(dir, "config")
	if err := os.MkdirAll(cfgDir, 0o755); err != nil {
		t.Fatal(err)
	}
	p := writeConfig(t, cfgDir, baseJSON(""))
	c, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if c.Dir() != cfgDir {
		t.Fatalf("Dir = %q, want %q", c.Dir(), cfgDir)
	}
	if got, want := c.WorkPath(), filepath.Join(dir, "build"); got != want {
		t.Fatalf("WorkPath = %q, want %q", got, want)
	}
	if got, want := c.UnisonPath(), filepath.Join(dir, "build", "unison"); got != want {
		t.Fatalf("UnisonPath = %q, want %q", got, want)
	}
	if got, want := c.PhraseExamplePath(), filepath.Join(cfgDir, "common", "custom_phrase_user.dict.yaml"); got != want {
		t.Fatalf("PhraseExample = %q, want %q", got, want)
	}
	if got, want := c.UserPhraseFile, "custom_phrase_user.dict.yaml"; got != want {
		t.Fatalf("UserPhraseFile = %q, want %q", got, want)
	}
	if got, want := c.SyncWaitSeconds, 180; got != want {
		t.Fatalf("SyncWaitSeconds = %d, want %d", got, want)
	}
	if got, want := c.GitHubAPIBase, "https://api.github.com"; got != want {
		t.Fatalf("GitHubAPIBase = %q, want %q", got, want)
	}
	f := c.Frontends[0]
	if f.Active != Auto {
		t.Fatalf("Active = %v, want auto", f.Active)
	}
	if f.SyncCompletion != CompletionState {
		t.Fatalf("SyncCompletion = %q, want state", f.SyncCompletion)
	}
	if f.Commands.Sync == nil || f.Commands.Sync.Executable != SquirrelExecutable {
		t.Fatalf("default Squirrel sync command missing: %+v", f.Commands.Sync)
	}
	if len(f.Commands.Sync.Args) != 1 || f.Commands.Sync.Args[0] != "--sync" {
		t.Fatalf("default Squirrel sync args = %v", f.Commands.Sync.Args)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home directory")
	}
	if got, want := c.Target(f), filepath.Join(home, "Library", "Rime"); got != want {
		t.Fatalf("Target = %q, want %q", got, want)
	}
}

func TestPhraseExampleDefault(t *testing.T) {
	body := strings.Replace(baseJSON(""), `"phrase_example": "common/custom_phrase_user.dict.yaml",`, "", 1)
	dir := t.TempDir()
	c, err := Load(writeConfig(t, dir, body))
	if err != nil {
		t.Fatal(err)
	}
	if got, want := c.PhraseExamplePath(), filepath.Join(dir, DefaultPhraseExample); got != want {
		t.Fatalf("PhraseExamplePath = %q, want %q", got, want)
	}
}

func TestActiveTriState(t *testing.T) {
	cases := []struct {
		json string
		want TriState
	}{
		{"true", On},
		{"false", Off},
		{`"auto"`, Auto},
		{`"AUTO"`, Auto},
		{`"true"`, On},
	}
	for _, tc := range cases {
		var got TriState
		if err := got.UnmarshalJSON([]byte(tc.json)); err != nil {
			t.Fatalf("UnmarshalJSON(%s): %v", tc.json, err)
		}
		if got != tc.want {
			t.Fatalf("UnmarshalJSON(%s) = %v, want %v", tc.json, got, tc.want)
		}
	}
	var bad TriState
	if err := bad.UnmarshalJSON([]byte(`"sometimes"`)); err == nil {
		t.Fatal("invalid tri-state value must fail")
	}
}

func TestActiveForPlatform(t *testing.T) {
	squirrel := Frontend{Name: "s", Kind: KindSquirrel}
	weasel := Frontend{Name: "w", Kind: KindWeasel}
	if !squirrel.ActiveFor("darwin") || squirrel.ActiveFor("windows") {
		t.Fatal("auto Squirrel must only be active on darwin")
	}
	if !weasel.ActiveFor("windows") || weasel.ActiveFor("darwin") {
		t.Fatal("auto Weasel must only be active on windows")
	}
	always := Frontend{Name: "a", Kind: KindWeasel, Active: On}
	if !always.ActiveFor("darwin") {
		t.Fatal("active=true must override the platform default")
	}
	never := Frontend{Name: "n", Kind: KindSquirrel, Active: Off}
	if never.ActiveFor("darwin") {
		t.Fatal("active=false must disable the frontend")
	}
}

func TestLoadExampleFile(t *testing.T) {
	root := repoRoot(t)
	p := filepath.Join(root, "config", "frontends.json.example")
	data, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("missing example config: %v", err)
	}
	for _, leaked := range []string{"/Users/", "/home/", `\Users\`} {
		if strings.Contains(string(data), leaked) {
			t.Fatalf("example config contains an absolute home path %q", leaked)
		}
	}
	c, err := Load(p)
	if err != nil {
		t.Fatalf("example config is invalid: %v", err)
	}
	foundSquirrel := false
	for _, f := range c.Frontends {
		if f.Kind == KindSquirrel {
			foundSquirrel = true
		}
		if layer := c.FrontendUILayer(f); layer != "" {
			if _, err := os.Stat(layer); err != nil {
				t.Fatalf("example ui_layer of %s missing: %v", f.Name, err)
			}
		}
	}
	if !foundSquirrel {
		t.Fatal("example config must contain a squirrel frontend")
	}
	if c.CloudSync == nil {
		t.Fatal("example config must contain cloud_sync")
	}
	// Every resource the example references must exist, or a copied config
	// fails immediately.
	for _, dir := range []string{c.LocalLayerPath(), c.CommonUILayerPath()} {
		if _, err := os.Stat(dir); err != nil {
			t.Fatalf("example layer directory missing: %v", err)
		}
	}
	if _, err := os.Stat(c.PhraseExamplePath()); err != nil {
		t.Fatalf("phrase template missing: %v", err)
	}
}

func TestLoadRejectsBadConfig(t *testing.T) {
	cases := map[string]string{
		"bad json":         `{"frontends": [}`,
		"missing work":     `{"frontends": [{"name": "s", "kind": "squirrel", "target_dir": "~/Rime"}]}`,
		"unknown kind":     strings.Replace(baseJSON(""), `"kind": "squirrel"`, `"kind": "other"`, 1),
		"no target":        strings.Replace(baseJSON(""), `"target_dir": "~/Library/Rime"`, `"target_dir": ""`, 1),
		"no frontends":     `{"work_dir": "build", "frontends": []}`,
		"bad active":       strings.Replace(baseJSON(""), `"active": "auto"`, `"active": "sometimes"`, 1),
		"empty exclude":    strings.Replace(baseJSON(""), `"exclude": ["*.log"]`, `"exclude": [""]`, 1),
		"phrase nested":    strings.Replace(baseJSON(""), `"local_layer": "local",`, `"local_layer": "local", "user_phrase_file": "custom/p.dict.yaml",`, 1),
		"bad completion":   strings.Replace(baseJSON(""), `"exclude": ["*.log"]`, `"exclude": ["*.log"], "sync_completion": "magic"`, 1),
		"bad wait":         strings.Replace(baseJSON(""), `"local_layer": "local",`, `"sync_wait_seconds": -1, "local_layer": "local",`, 1),
		"unknown field":    strings.Replace(baseJSON(""), `"local_layer": "local",`, `"local_layer": "local", "state_dir": "state",`, 1),
		"retired layer":    strings.Replace(baseJSON(""), `"local_layer": "local",`, `"local_layer": "local", "bootstrap_layer": "bootstrap",`, 1),
		"trailing brace":   baseJSON("") + "}",
		"trailing object":  baseJSON("") + ` {"work_dir": "x"}`,
		"relative log dir": strings.Replace(baseJSON(""), `"exclude": ["*.log"]`, `"exclude": ["*.log"], "sync_log_dir": "logs"`, 1),
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := Load(writeConfig(t, t.TempDir(), body)); err == nil {
				t.Fatalf("invalid config %s must be rejected", name)
			}
		})
	}
}

func TestSquirrelRejectsProcessCompletion(t *testing.T) {
	body := strings.Replace(baseJSON(""), `"exclude": ["*.log"]`, `"exclude": ["*.log"], "sync_completion": "process"`, 1)
	if _, err := Load(writeConfig(t, t.TempDir(), body)); err == nil {
		t.Fatal("Squirrel commands are asynchronous; process completion must be rejected")
	}
}

func TestWeaselCompletionDefaultsToLog(t *testing.T) {
	process := `{"work_dir": "build", "frontends": [{
		"name": "w", "kind": "weasel", "active": true, "target_dir": "~/Rime",
		"commands": {"deploy": {"executable": "WeaselDeployer.exe"}, "sync": {"executable": "WeaselDeployer.exe"}},
		"sync_completion": "process"
	}]}`
	if _, err := Load(writeConfig(t, t.TempDir(), process)); err == nil {
		t.Fatal("Weasel process completion must be rejected")
	}
	byDefault := `{"work_dir": "build", "frontends": [{
		"name": "w", "kind": "weasel", "active": true, "target_dir": "~/Rime",
		"commands": {"sync": {"executable": "WeaselDeployer.exe"}}
	}]}`
	c, err := Load(writeConfig(t, t.TempDir(), byDefault))
	if err != nil {
		t.Fatalf("default Weasel config must be valid: %v", err)
	}
	if c.Frontends[0].SyncCompletion != CompletionLog {
		t.Fatalf("Weasel default completion = %q, want log", c.Frontends[0].SyncCompletion)
	}
	if got := SyncLogDirectory(c.Frontends[0]); !strings.HasSuffix(got, "rime.weasel") {
		t.Fatalf("Weasel default log directory = %q", got)
	}
}

func TestRejectsMalformedExcludePattern(t *testing.T) {
	body := strings.Replace(baseJSON(""), `"exclude": ["*.log"]`, `"exclude": ["[bad"]`, 1)
	if _, err := Load(writeConfig(t, t.TempDir(), body)); err == nil {
		t.Fatal("malformed glob must be rejected")
	}
}

func TestRejectsNestedLayers(t *testing.T) {
	body := strings.Replace(baseJSON(""), `"ui_layer": "frontends/squirrel"`, `"ui_layer": "local/squirrel"`, 1)
	if _, err := Load(writeConfig(t, t.TempDir(), body)); err == nil {
		t.Fatal("nested layer directories must be rejected")
	}
}

func TestPathsOverlapResolvesAliases(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(root, "alias")
	if err := os.Symlink(target, alias); err != nil {
		t.Skipf("cannot create symlink: %v", err)
	}
	if !PathsOverlap(alias, target) {
		t.Fatal("a symlink alias must count as overlap")
	}
	if !PathsOverlap(filepath.Join(alias, "missing"), target) {
		t.Fatal("an existing symlinked prefix must be resolved")
	}
}

func TestLayerEqualToWorkDirRejected(t *testing.T) {
	body := strings.Replace(baseJSON(""), `"work_dir": "../build",`, `"work_dir": "local",`, 1)
	if _, err := Load(writeConfig(t, t.TempDir(), body)); err == nil {
		t.Fatal("local_layer equal to work_dir must be rejected")
	}
}

func TestDuplicateFrontendNames(t *testing.T) {
	body := `{"work_dir": "build", "frontends": [
		{"name": "a", "kind": "squirrel", "target_dir": "~/Rime"},
		{"name": "a", "kind": "weasel", "target_dir": "~/Rime2"}
	]}`
	if _, err := Load(writeConfig(t, t.TempDir(), body)); err == nil {
		t.Fatal("duplicate names must fail")
	}
}

func TestCleanRelative(t *testing.T) {
	for _, p := range []string{"a.yaml", "dicts/a.dict.yaml", "./a/b.yaml"} {
		if _, err := CleanRelative(p); err != nil {
			t.Fatalf("CleanRelative(%q): %v", p, err)
		}
	}
	for _, p := range []string{"", "/etc/passwd", "../x", "a/../../b", `C:\Windows`, `\server\share`} {
		if _, err := CleanRelative(p); err == nil {
			t.Fatalf("CleanRelative(%q) must fail", p)
		}
	}
}

func TestDefaultPath(t *testing.T) {
	exe := filepath.Join("opt", "rime-config", "rime-config")
	want := filepath.Join("opt", "rime-config", "config", "frontends.json")
	if got := DefaultPath(exe); got != want {
		t.Fatalf("DefaultPath = %q, want %q", got, want)
	}
}

func TestExpandUser(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home directory")
	}
	if got, want := ExpandUser("~/bin/unison"), filepath.Join(home, "bin", "unison"); got != want {
		t.Fatalf("ExpandUser(~/bin/unison) = %q, want %q", got, want)
	}
	if got := ExpandUser("unison"); got != "unison" {
		t.Fatalf("ExpandUser must not rewrite a plain command name: %q", got)
	}
}

func repoRoot(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate the test file")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(file), "..", ".."))
}
