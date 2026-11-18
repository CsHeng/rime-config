package app

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// fixture builds a self-contained environment: a local GitHub-like server, a
// configuration file, layers, a Rime target and fake native programs.
type fixture struct {
	t         *testing.T
	root      string
	platform  string
	cfgDir    string
	cfgPath   string
	target    string
	events    string
	serverURL string
	requests  *atomic.Int32
	downloads *atomic.Int32
	binDir    string
	logDir    string
	syncDir   string
	self      string
}

const installationID = "Squirrel-Test-Mac"

// The app tests reuse the test binary as a fake native frontend. The child
// runs this init first, performs the frontend's visible side effects and
// exits before the test framework starts.
func init() {
	if os.Getenv("RIME_CONFIG_TEST_HELPER") != "1" {
		return
	}
	helperMain()
	os.Exit(0)
}

// helperMain models a frontend. Squirrel-style modes change the durable Rime
// state (user.yaml, sync snapshots) and deliberately write no INFO completion
// line, like a long-running IME whose glog buffer is not flushed. Weasel-style
// "log-*" modes write the completion summary, like a process that exits.
func helperMain() {
	mode := ""
	if len(os.Args) > 1 {
		mode = os.Args[1]
	}
	appendLine(os.Getenv("RIME_CONFIG_TEST_EVENTS"), mode)
	target := os.Getenv("RIME_CONFIG_TEST_TARGET")
	logDir := os.Getenv("RIME_CONFIG_TEST_LOGDIR")
	logPath := filepath.Join(logDir, fmt.Sprintf("rime.squirrel.test.log.INFO.20260101-000000.%d.log", os.Getpid()))
	line := func(level, thread, msg string) string {
		now := time.Now()
		return fmt.Sprintf("%s%s %s %s %s\n", level, now.Format("20060102"), now.Format("15:04:05.000000"), thread, msg)
	}
	switch mode {
	case "deploy-ok":
		writeBuildTime(target)
	case "deploy-fail":
		appendLine(logPath, strings.TrimSuffix(line("I", "0xW", "deployer.cc:80] running deployment tasks:")+
			line("E", "0xW", "deployment_tasks.cc:300] error building schema 'broken'"), "\n"))
		writeBuildTime(target)
	case "sync-ok":
		writeSnapshots(target, os.Getenv("RIME_CONFIG_TEST_SYNCDIR"))
	case "sync-hang":
		// Submitted, but the frontend never finishes.
	case "log-sync-ok":
		appendLine(logPath, strings.TrimSuffix(line("I", "0x1", "user_dict_manager.cc:213] synchronizing 1 user dicts.")+
			line("I", "0x1", "deployer.cc:97] 3 tasks ran: 3 success, 0 failure."), "\n"))
	case "log-sync-fail":
		appendLine(logPath, strings.TrimSuffix(line("I", "0x1", "user_dict_manager.cc:213] synchronizing 1 user dicts.")+
			line("I", "0x1", "deployer.cc:97] 3 tasks ran: 0 success, 3 failure."), "\n"))
	}
}

func appendLine(p, s string) {
	if p == "" {
		return
	}
	_ = os.MkdirAll(filepath.Dir(p), 0o755)
	f, err := os.OpenFile(p, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintln(f, s)
}

func writeBuildTime(target string) {
	_ = os.WriteFile(filepath.Join(target, "user.yaml"),
		[]byte(fmt.Sprintf("var:\n  last_build_time: %d\n", time.Now().Unix())), 0o644)
}

func writeSnapshots(target, syncDir string) {
	entries, _ := os.ReadDir(target)
	for _, e := range entries {
		if e.IsDir() && strings.HasSuffix(e.Name(), ".userdb") {
			dir := filepath.Join(syncDir, installationID)
			_ = os.MkdirAll(dir, 0o755)
			_ = os.WriteFile(filepath.Join(dir, e.Name()+".txt"), []byte("snapshot\n"), 0o644)
		}
	}
}

func zipFixture(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var buf bytes.Buffer
	w := zip.NewWriter(&buf)
	names := make([]string, 0, len(files))
	for name := range files {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		f, err := w.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := f.Write([]byte(files[name])); err != nil {
			t.Fatal(err)
		}
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// prepareRimeDir creates a Rime user directory the way a frontend leaves it:
// installation.yaml with an id and sync_dir, user.yaml with an old build time
// and one user dictionary.
func (f *fixture) prepareRimeDir(dir string) {
	f.t.Helper()
	writeFile(f.t, filepath.Join(dir, "installation.yaml"),
		fmt.Sprintf("installation_id: %q\nsync_dir: %q\n", installationID, f.syncDir))
	writeFile(f.t, filepath.Join(dir, "user.yaml"), "var:\n  last_build_time: 1000\n")
	if err := os.MkdirAll(filepath.Join(dir, "wanxiang.userdb"), 0o755); err != nil {
		f.t.Fatal(err)
	}
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	f := &fixture{
		t:         t,
		root:      t.TempDir(),
		platform:  "darwin",
		requests:  &atomic.Int32{},
		downloads: &atomic.Int32{},
	}
	f.target = filepath.Join(f.root, "target")
	f.events = filepath.Join(f.root, "events.log")
	f.logDir = filepath.Join(f.root, "logs")
	f.binDir = filepath.Join(f.root, "bin")
	f.syncDir = filepath.Join(f.root, "sync")
	f.cfgDir = filepath.Join(f.root, "config")
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	f.self = self
	t.Setenv("RIME_CONFIG_TEST_HELPER", "1")
	t.Setenv("RIME_CONFIG_TEST_EVENTS", f.events)
	t.Setenv("RIME_CONFIG_TEST_LOGDIR", f.logDir)
	t.Setenv("RIME_CONFIG_TEST_TARGET", f.target)
	t.Setenv("RIME_CONFIG_TEST_SYNCDIR", f.syncDir)
	for _, d := range []string{f.target, f.binDir, f.logDir,
		filepath.Join(f.cfgDir, "local"),
		filepath.Join(f.cfgDir, "common"),
		filepath.Join(f.cfgDir, "frontends", "squirrel"),
	} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	f.prepareRimeDir(f.target)
	writeFile(t, filepath.Join(f.cfgDir, "local", "wanxiang.custom.yaml"), "local: true\n")
	writeFile(t, filepath.Join(f.cfgDir, "common", "wanxiang_phrase.custom.yaml"), "common: true\n")
	writeFile(t, filepath.Join(f.cfgDir, "custom_phrase_user.dict.yaml.example"), "template\n")
	writeFile(t, filepath.Join(f.cfgDir, "frontends", "squirrel", "squirrel.custom.yaml"), "ui: true\n")

	base := zipFixture(t, map[string]string{
		"default.yaml":         "upstream\n",
		"dicts/en.dict.yaml":   "upstream-dict\n",
		"custom/wanxiang.yaml": "custom\n",
	})
	dicts := zipFixture(t, map[string]string{"zi.dict.yaml": "nightly\n"})
	model := []byte("gram")

	releases := map[string][]map[string]any{
		"amzxyz/rime-wanxiang": {
			{
				"tag_name": "dict-nightly", "draft": false, "created_at": "2026-01-02T00:00:00Z",
				"assets": []map[string]any{{
					"name": "base-dicts.zip", "size": len(dicts), "updated_at": "2026-01-02T00:00:00Z",
				}},
			},
			{
				"tag_name": "v1.0.0", "draft": false, "created_at": "2026-01-01T00:00:00Z",
				"assets": []map[string]any{{
					"name": "rime-wanxiang-base.zip", "size": len(base), "updated_at": "2026-01-01T00:00:00Z",
				}},
			},
		},
		"amzxyz/rime-wanxiang-data": {
			{
				"tag_name": "LTS", "draft": false, "created_at": "2026-01-03T00:00:00Z",
				"assets": []map[string]any{{
					"name": "wanxiang-lts-zh-hans.gram", "size": len(model), "updated_at": "2026-01-03T00:00:00Z",
				}},
			},
		},
	}
	assets := map[string][]byte{
		"rime-wanxiang-base.zip":    base,
		"base-dicts.zip":            dicts,
		"wanxiang-lts-zh-hans.gram": model,
	}
	var srv *httptest.Server
	srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/repos/") {
			f.requests.Add(1)
			repo := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/repos/"), "/releases")
			body, ok := releases[repo]
			if !ok {
				http.NotFound(w, r)
				return
			}
			for _, rel := range body {
				for _, a := range rel["assets"].([]map[string]any) {
					a["browser_download_url"] = srv.URL + "/dl/" + a["name"].(string)
				}
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(body)
			return
		}
		data, ok := assets[strings.TrimPrefix(r.URL.Path, "/dl/")]
		if !ok {
			http.NotFound(w, r)
			return
		}
		f.downloads.Add(1)
		_, _ = w.Write(data)
	}))
	t.Cleanup(srv.Close)
	f.serverURL = srv.URL

	// Fake Unison: records its run and the archive directory in the shared
	// event stream, so ordering against the Rime steps is observable.
	writeFile(t, filepath.Join(f.binDir, "unison.sh"),
		fmt.Sprintf("#!/bin/sh\necho \"unison UNISON=$UNISON\" >> %q\n", f.events))
	if err := os.Chmod(filepath.Join(f.binDir, "unison.sh"), 0o755); err != nil {
		t.Fatal(err)
	}

	f.cfgPath = filepath.Join(f.cfgDir, "frontends.json")
	return f
}

func (f *fixture) cloudConfig() string {
	one := filepath.Join(f.root, "onedrive")
	cloud := filepath.Join(f.root, "icloud")
	for _, d := range []string{one, cloud} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			f.t.Fatal(err)
		}
	}
	return fmt.Sprintf(`,
  "cloud_sync": {"unison": %q, "one_drive_dir": %q, "i_cloud_dir": %q}`,
		filepath.Join(f.binDir, "unison.sh"), one, cloud)
}

func (f *fixture) squirrelFrontend(name, target, deployMode, syncMode string) string {
	return fmt.Sprintf(`{
      "name": %q,
      "kind": "squirrel",
      "active": true,
      "target_dir": %q,
      "ui_layer": "frontends/squirrel",
      "exclude": ["*.log"],
      "commands": {
        "deploy": {"executable": %q, "args": [%q]},
        "sync": {"executable": %q, "args": [%q]}
      },
      "sync_log_dir": %q
    }`, name, target, f.self, deployMode, f.self, syncMode, f.logDir)
}

func (f *fixture) squirrel(deployMode, syncMode string) string {
	return f.squirrelFrontend("squirrel", f.target, deployMode, syncMode)
}

func (f *fixture) weaselFrontend(deployMode, syncMode string) string {
	return fmt.Sprintf(`{
      "name": "weasel",
      "kind": "weasel",
      "active": true,
      "target_dir": %q,
      "commands": {
        "deploy": {"executable": %q, "args": [%q]},
        "sync": {"executable": %q, "args": [%q]}
      },
      "sync_completion": "log",
      "sync_log_dir": %q
    }`, f.target, f.self, deployMode, f.self, syncMode, f.logDir)
}

func (f *fixture) writeConfig(extra string, frontends ...string) {
	f.t.Helper()
	if len(frontends) == 0 {
		frontends = []string{f.squirrel("deploy-ok", "sync-ok")}
	}
	body := fmt.Sprintf(`{
  "github_api_base": %q,
  "work_dir": "../build",
  "local_layer": "local",
  "common_ui_layer": "common",
  "sync_wait_seconds": 2,
  "frontends": [
    %s
  ]%s
}
`, f.serverURL, strings.Join(frontends, ",\n    "), extra)
	writeFile(f.t, f.cfgPath, body)
}

func writeFile(t *testing.T, p, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func readFile(t *testing.T, p string) string {
	t.Helper()
	data, err := os.ReadFile(p)
	if err != nil {
		return ""
	}
	return string(data)
}

// eventList returns the native steps in the order they ran.
func (f *fixture) eventList() []string {
	var out []string
	for _, l := range strings.Split(strings.TrimSpace(readFile(f.t, f.events)), "\n") {
		if l != "" {
			out = append(out, l)
		}
	}
	return out
}

func (f *fixture) run(t *testing.T, args ...string) (int, string, string) {
	t.Helper()
	var out, errOut bytes.Buffer
	a := &App{
		Stdout:     &out,
		Stderr:     &errOut,
		Platform:   f.platform,
		Executable: filepath.Join(f.root, "rime-config"),
		Getenv:     func(string) string { return "" },
		Now:        time.Now,
		Settle:     200 * time.Millisecond,
	}
	code := a.Run(context.Background(), args)
	return code, out.String(), errOut.String()
}

func (f *fixture) noSideEffects(t *testing.T) {
	t.Helper()
	if len(f.eventList()) != 0 {
		t.Fatalf("no native command may run: %v", f.eventList())
	}
	if f.downloads.Load() != 0 {
		t.Fatal("nothing may be downloaded")
	}
	if _, err := os.Stat(filepath.Join(f.target, "default.yaml")); err == nil {
		t.Fatal("the target must not be written")
	}
}

func TestUpdateEndToEnd(t *testing.T) {
	f := newFixture(t)
	f.writeConfig("")
	code, stdout, stderr := f.run(t, "--config", f.cfgPath)
	if code != ExitOK {
		t.Fatalf("exit = %d\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	for _, rel := range []string{"default.yaml", "dicts/zi.dict.yaml", "wanxiang.custom.yaml", "squirrel.custom.yaml", "wanxiang_phrase.custom.yaml"} {
		if _, err := os.Stat(filepath.Join(f.target, filepath.FromSlash(rel))); err != nil {
			t.Fatalf("target lacks %s: %v", rel, err)
		}
	}
	if got := readFile(t, filepath.Join(f.target, "custom_phrase_user.dict.yaml")); got != "template\n" {
		t.Fatalf("the phrase template must seed a missing phrase file: %q", got)
	}
	if got := readFile(t, filepath.Join(f.target, "default.yaml")); got != "upstream\n" {
		t.Fatalf("upstream content: %q", got)
	}
	// The fake frontend never writes a completion log line; completion
	// comes from the Rime state alone.
	if got := f.eventList(); strings.Join(got, ",") != "deploy-ok,sync-ok" {
		t.Fatalf("native steps = %v, want deploy then sync", got)
	}
	if _, err := os.Stat(filepath.Join(f.root, "build", "cache", "base", "marker.json")); err != nil {
		t.Fatalf("resource cache marker missing: %v", err)
	}
	for _, p := range []string{filepath.Join(f.root, "state"), filepath.Join(f.cfgDir, "state")} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Fatalf("no state directory may be created: %s", p)
		}
	}
}

func TestDeployWorkerErrorStopsBeforeSync(t *testing.T) {
	f := newFixture(t)
	f.writeConfig("", f.squirrel("deploy-fail", "sync-ok"))
	code, _, stderr := f.run(t, "--config", f.cfgPath)
	if code != ExitFailure {
		t.Fatalf("exit = %d, want %d: %s", code, ExitFailure, stderr)
	}
	if !strings.Contains(stderr, "error building schema 'broken'") {
		t.Fatalf("stderr must show the frontend error: %s", stderr)
	}
	if got := f.eventList(); strings.Join(got, ",") != "deploy-fail" {
		t.Fatalf("sync must not run after a failed deploy: %v", got)
	}
}

func TestExistingCustomizationIsReplacedVisibly(t *testing.T) {
	f := newFixture(t)
	f.writeConfig("")
	writeFile(t, filepath.Join(f.target, "wanxiang.custom.yaml"), "hand written on the device\n")

	code, stdout, stderr := f.run(t, "--config", f.cfgPath, "--dry-run")
	if code != ExitOK {
		t.Fatalf("exit = %d: %s", code, stderr)
	}
	if !strings.Contains(stdout, "update wanxiang.custom.yaml") {
		t.Fatalf("the plan must show that an existing file will be replaced:\n%s", stdout)
	}
	if got := readFile(t, filepath.Join(f.target, "wanxiang.custom.yaml")); got != "hand written on the device\n" {
		t.Fatalf("dry-run replaced the file: %q", got)
	}

	code, _, stderr = f.run(t, "--config", f.cfgPath, "--no-redeploy", "--no-sync")
	if code != ExitOK {
		t.Fatalf("exit = %d: %s", code, stderr)
	}
	if !strings.Contains(stderr, "replaced existing") {
		t.Fatalf("the summary must count replaced files: %s", stderr)
	}
	if got := readFile(t, filepath.Join(f.target, "wanxiang.custom.yaml")); got != "local: true\n" {
		t.Fatalf("the repository layer is the source of truth: %q", got)
	}
}

func TestRepositoryPhraseFileIsDistributed(t *testing.T) {
	f := newFixture(t)
	f.writeConfig("")
	writeFile(t, filepath.Join(f.cfgDir, "local", "custom_phrase_user.dict.yaml"), "repository phrases\n")
	writeFile(t, filepath.Join(f.target, "custom_phrase_user.dict.yaml"), "older device phrases\n")
	if code, _, stderr := f.run(t, "--config", f.cfgPath, "--no-redeploy", "--no-sync"); code != ExitOK {
		t.Fatalf("update: %s", stderr)
	}
	if got := readFile(t, filepath.Join(f.target, "custom_phrase_user.dict.yaml")); got != "repository phrases\n" {
		t.Fatalf("the repository phrase file must replace the target copy: %q", got)
	}
}

func TestDevicePhraseFileKeptWithoutRepositoryCopy(t *testing.T) {
	f := newFixture(t)
	f.writeConfig("")
	writeFile(t, filepath.Join(f.target, "custom_phrase_user.dict.yaml"), "device phrases\n")
	if code, _, stderr := f.run(t, "--config", f.cfgPath, "--no-redeploy", "--no-sync", "--delete"); code != ExitOK {
		t.Fatalf("update: %s", stderr)
	}
	if got := readFile(t, filepath.Join(f.target, "custom_phrase_user.dict.yaml")); got != "device phrases\n" {
		t.Fatalf("the device phrase file must stay: %q", got)
	}
}

func TestSyncOnlySkipsDownloadAndDeploy(t *testing.T) {
	f := newFixture(t)
	f.writeConfig("")
	code, _, stderr := f.run(t, "--config", f.cfgPath, "--sync-only")
	if code != ExitOK {
		t.Fatalf("exit = %d: %s", code, stderr)
	}
	if f.requests.Load() != 0 {
		t.Fatal("--sync-only must not query the resource API")
	}
	if got := f.eventList(); strings.Join(got, ",") != "sync-ok" {
		t.Fatalf("--sync-only must only sync: %v", got)
	}
	if _, err := os.Stat(filepath.Join(f.target, "default.yaml")); !os.IsNotExist(err) {
		t.Fatalf("--sync-only must not distribute: %v", err)
	}
}

func TestSyncTimeoutIsAFailure(t *testing.T) {
	f := newFixture(t)
	f.writeConfig("", f.squirrel("deploy-ok", "sync-hang"))
	start := time.Now()
	code, _, stderr := f.run(t, "--config", f.cfgPath, "--sync-only")
	if code != ExitFailure {
		t.Fatalf("exit = %d, want %d: %s", code, ExitFailure, stderr)
	}
	if !strings.Contains(stderr, "wanxiang") || time.Since(start) > 10*time.Second {
		t.Fatalf("the timeout must name the pending dictionary within the bound: %s", stderr)
	}
}

func TestSyncOnlyRequiresDesktopFrontend(t *testing.T) {
	f := newFixture(t)
	f.writeConfig("", `{
      "name": "hamster3",
      "kind": "hamster3",
      "active": true,
      "target_dir": "`+filepath.Join(f.root, "ios")+`"
    }`)
	code, _, stderr := f.run(t, "--config", f.cfgPath, "--sync-only")
	if code != ExitUsage {
		t.Fatalf("exit = %d, want %d: %s", code, ExitUsage, stderr)
	}
	f.noSideEffects(t)
}

func TestSyncWithoutInstallationFailsBeforeSideEffects(t *testing.T) {
	f := newFixture(t)
	f.writeConfig("")
	if err := os.Remove(filepath.Join(f.target, "installation.yaml")); err != nil {
		t.Fatal(err)
	}
	code, _, stderr := f.run(t, "--config", f.cfgPath)
	if code != ExitUsage || !strings.Contains(stderr, "installation.yaml") {
		t.Fatalf("an unobservable sync must fail in preflight: %d %s", code, stderr)
	}
	f.noSideEffects(t)
}

func TestInvalidCombinationsRejectedBeforeSideEffects(t *testing.T) {
	for _, extra := range [][]string{
		{"--sync-only", "--no-sync"},
		{"--sync-only", "--delete"},
		{"--sync-only", "--target", "somewhere"},
		{"--sync-only", "--no-download"},
	} {
		f := newFixture(t)
		f.writeConfig("")
		code, _, stderr := f.run(t, append([]string{"--config", f.cfgPath}, extra...)...)
		if code != ExitUsage {
			t.Fatalf("%v exit = %d, want %d: %s", extra, code, ExitUsage, stderr)
		}
		f.noSideEffects(t)
	}
}

func TestHelpExitsZero(t *testing.T) {
	f := newFixture(t)
	for _, arg := range []string{"-h", "--help"} {
		code, stdout, stderr := f.run(t, arg)
		if code != ExitOK || !strings.Contains(stdout, "usage: rime-config") || stderr != "" {
			t.Fatalf("%s: exit=%d stdout=%q stderr=%q", arg, code, stdout, stderr)
		}
	}
}

func TestCloudSyncRejectedOnWindows(t *testing.T) {
	f := newFixture(t)
	f.platform = "windows"
	f.writeConfig(f.cloudConfig())
	code, _, stderr := f.run(t, "--config", f.cfgPath, "--cloud-sync")
	if code != ExitUsage {
		t.Fatalf("exit = %d, want %d: %s", code, ExitUsage, stderr)
	}
	f.noSideEffects(t)
}

func TestCloudSyncOrderAroundRimeSteps(t *testing.T) {
	f := newFixture(t)
	f.writeConfig(f.cloudConfig())
	code, _, stderr := f.run(t, "--config", f.cfgPath, "--cloud-sync")
	if code != ExitOK {
		t.Fatalf("exit = %d: %s", code, stderr)
	}
	unison := "unison UNISON=" + filepath.Join(f.root, "build", "unison")
	want := []string{"deploy-ok", unison, "sync-ok", unison}
	if got := f.eventList(); strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("steps = %q, want %q", got, want)
	}
}

func TestCloudSyncRunsOncePerSideForSeveralFrontends(t *testing.T) {
	f := newFixture(t)
	second := filepath.Join(f.root, "target2")
	f.prepareRimeDir(second)
	f.writeConfig(f.cloudConfig(),
		f.squirrel("deploy-ok", "sync-ok"),
		strings.Replace(f.squirrelFrontend("squirrel-2", second, "deploy-ok", "sync-ok"), `"ui_layer": "frontends/squirrel",`, "", 1))
	code, _, stderr := f.run(t, "--config", f.cfgPath, "--sync-only", "--cloud-sync")
	if code != ExitOK {
		t.Fatalf("exit = %d: %s", code, stderr)
	}
	got := f.eventList()
	if len(got) != 4 || !strings.HasPrefix(got[0], "unison") || got[1] != "sync-ok" || got[2] != "sync-ok" || !strings.HasPrefix(got[3], "unison") {
		t.Fatalf("one Unison run must wrap all frontend syncs: %q", got)
	}
}

func TestCloudSyncSkipsFinalRunAfterSyncFailure(t *testing.T) {
	f := newFixture(t)
	f.writeConfig(f.cloudConfig(), f.squirrel("deploy-ok", "sync-hang"))
	code, _, stderr := f.run(t, "--config", f.cfgPath, "--sync-only", "--cloud-sync")
	if code != ExitFailure {
		t.Fatalf("exit = %d, want %d: %s", code, ExitFailure, stderr)
	}
	got := f.eventList()
	if len(got) != 2 || !strings.HasPrefix(got[0], "unison") || got[1] != "sync-hang" {
		t.Fatalf("no Unison run may follow an unfinished sync: %q", got)
	}
}

func TestDryRunUpdateChangesNothing(t *testing.T) {
	f := newFixture(t)
	f.writeConfig(f.cloudConfig())
	writeFile(t, filepath.Join(f.target, "default.yaml"), "user-version\n")
	code, stdout, stderr := f.run(t, "--config", f.cfgPath, "--dry-run", "--cloud-sync")
	if code != ExitOK {
		t.Fatalf("exit = %d: %s", code, stderr)
	}
	if got := readFile(t, filepath.Join(f.target, "default.yaml")); got != "user-version\n" {
		t.Fatalf("dry-run replaced the target: %q", got)
	}
	for _, p := range []string{"squirrel.custom.yaml", "custom_phrase_user.dict.yaml"} {
		if _, err := os.Stat(filepath.Join(f.target, p)); !os.IsNotExist(err) {
			t.Fatalf("dry-run created %s", p)
		}
	}
	if len(f.eventList()) != 0 {
		t.Fatalf("dry-run ran native commands: %v", f.eventList())
	}
	if _, err := os.Stat(filepath.Join(f.root, "build", "unison")); !os.IsNotExist(err) {
		t.Fatal("dry-run created the Unison archive directory")
	}
	// The plan lists the steps in execution order.
	order := []string{"update default.yaml", "run    squirrel/deploy", "cloud sync (before Rime sync)", "run    squirrel/sync", "cloud sync (after Rime sync)"}
	last := -1
	for _, step := range order {
		i := strings.Index(stdout, step)
		if i < 0 || i < last {
			t.Fatalf("plan step %q missing or out of order:\n%s", step, stdout)
		}
		last = i
	}
}

func TestMissingProgramFailsBeforeSideEffects(t *testing.T) {
	f := newFixture(t)
	f.writeConfig("", strings.Replace(f.squirrel("deploy-ok", "sync-ok"),
		fmt.Sprintf(`"deploy": {"executable": %q`, f.self),
		fmt.Sprintf(`"deploy": {"executable": %q`, filepath.Join(f.root, "missing-deploy")), 1))
	code, _, stderr := f.run(t, "--config", f.cfgPath)
	if code != ExitUsage {
		t.Fatalf("exit = %d, want %d: %s", code, ExitUsage, stderr)
	}
	f.noSideEffects(t)
}

func TestTargetOverrideWritesOnlyThatTarget(t *testing.T) {
	f := newFixture(t)
	f.writeConfig("")
	override := filepath.Join(f.root, "sandbox")
	code, _, stderr := f.run(t, "--config", f.cfgPath, "--target", override, "--no-redeploy", "--no-sync")
	if code != ExitOK {
		t.Fatalf("exit = %d: %s", code, stderr)
	}
	if _, err := os.Stat(filepath.Join(override, "default.yaml")); err != nil {
		t.Fatalf("override target lacks files: %v", err)
	}
	if _, err := os.Stat(filepath.Join(f.target, "default.yaml")); !os.IsNotExist(err) {
		t.Fatalf("the configured target was written: %v", err)
	}
}

func TestTargetOverrideRequiresNativeStepsDisabled(t *testing.T) {
	f := newFixture(t)
	f.writeConfig("")
	code, _, stderr := f.run(t, "--config", f.cfgPath, "--target", filepath.Join(f.root, "sandbox"))
	if code != ExitUsage || !strings.Contains(stderr, "--no-redeploy") {
		t.Fatalf("exit = %d, want %d naming --no-redeploy: %s", code, ExitUsage, stderr)
	}
}

func TestInactiveFrontendMayShareTarget(t *testing.T) {
	f := newFixture(t)
	f.writeConfig("", f.squirrel("deploy-ok", "sync-ok"), fmt.Sprintf(`{
      "name": "hamster3",
      "kind": "hamster3",
      "active": false,
      "target_dir": %q
    }`, f.target))
	if code, _, stderr := f.run(t, "--config", f.cfgPath, "--sync-only", "--dry-run"); code != ExitOK {
		t.Fatalf("an inactive frontend sharing the target must not block: %d %s", code, stderr)
	}
}

func TestActiveFrontendsWithOverlappingTargetsRejected(t *testing.T) {
	f := newFixture(t)
	f.writeConfig("", f.squirrel("deploy-ok", "sync-ok"), fmt.Sprintf(`{
      "name": "hamster3",
      "kind": "hamster3",
      "active": true,
      "target_dir": %q
    }`, filepath.Join(f.target, "nested")))
	if code, _, stderr := f.run(t, "--config", f.cfgPath, "--sync-only", "--dry-run"); code != ExitUsage {
		t.Fatalf("overlapping active targets must be rejected: %d %s", code, stderr)
	}
}

func TestTargetOverrideRejectedWithMultipleFrontends(t *testing.T) {
	f := newFixture(t)
	f.writeConfig("", f.squirrel("deploy-ok", "sync-ok"), fmt.Sprintf(`{
      "name": "hamster3",
      "kind": "hamster3",
      "active": true,
      "target_dir": %q
    }`, filepath.Join(f.root, "other-target")))
	code, _, stderr := f.run(t, "--config", f.cfgPath, "--target", filepath.Join(f.root, "sandbox"), "--no-redeploy", "--no-sync")
	if code != ExitUsage {
		t.Fatalf("exit = %d, want %d: %s", code, ExitUsage, stderr)
	}
}

func TestNoDownloadWithoutCacheFails(t *testing.T) {
	f := newFixture(t)
	f.writeConfig("")
	code, _, stderr := f.run(t, "--config", f.cfgPath, "--no-download")
	if code != ExitFailure || !strings.Contains(stderr, "no-download") {
		t.Fatalf("exit = %d, want %d naming --no-download: %s", code, ExitFailure, stderr)
	}
	f.noSideEffects(t)
}

func TestTargetOverlappingInputsRejected(t *testing.T) {
	for name, rel := range map[string]string{
		"config dir": "config",
		"work dir":   "build",
		"layer dir":  filepath.Join("config", "local"),
	} {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			f.writeConfig("")
			code, _, stderr := f.run(t, "--config", f.cfgPath, "--target", filepath.Join(f.root, rel), "--no-redeploy", "--no-sync")
			if code != ExitUsage {
				t.Fatalf("exit = %d, want %d: %s", code, ExitUsage, stderr)
			}
			f.noSideEffects(t)
		})
	}
}

func TestMissingUnisonFailsBeforeSideEffects(t *testing.T) {
	f := newFixture(t)
	cloud := strings.Replace(f.cloudConfig(), filepath.Join(f.binDir, "unison.sh"), filepath.Join(f.root, "missing-unison"), 1)
	f.writeConfig(cloud)
	code, _, stderr := f.run(t, "--config", f.cfgPath, "--sync-only", "--cloud-sync")
	if code != ExitUsage {
		t.Fatalf("exit = %d, want %d: %s", code, ExitUsage, stderr)
	}
	f.noSideEffects(t)
}

func TestSymlinkedUnisonArchiveFailsBeforeSideEffects(t *testing.T) {
	f := newFixture(t)
	f.writeConfig(f.cloudConfig())
	outside := filepath.Join(f.root, "outside-archive")
	if err := os.MkdirAll(outside, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(f.root, "build"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(f.root, "build", "unison")); err != nil {
		t.Fatal(err)
	}
	code, _, stderr := f.run(t, "--config", f.cfgPath, "--sync-only", "--cloud-sync")
	if code != ExitUsage || !strings.Contains(stderr, "unison") {
		t.Fatalf("exit = %d, want %d naming the archive: %s", code, ExitUsage, stderr)
	}
	f.noSideEffects(t)
}

func TestSyncOnlyDoesNotRequireUpdateInputs(t *testing.T) {
	f := newFixture(t)
	f.writeConfig("", strings.Replace(f.squirrel("deploy-ok", "sync-ok"),
		`"ui_layer": "frontends/squirrel"`, `"ui_layer": "missing-ui-layer"`, 1))
	if err := os.RemoveAll(filepath.Join(f.cfgDir, "local")); err != nil {
		t.Fatal(err)
	}
	code, stdout, stderr := f.run(t, "--config", f.cfgPath, "--sync-only", "--dry-run")
	if code != ExitOK {
		t.Fatalf("--sync-only must not need update inputs: %d %s", code, stderr)
	}
	if !strings.Contains(stdout, "squirrel/sync") {
		t.Fatalf("dry-run must print the sync plan: %s", stdout)
	}
	f.noSideEffects(t)
}

func TestPhysicalAliasTargetRejected(t *testing.T) {
	f := newFixture(t)
	alias := filepath.Join(f.root, "work-alias")
	if err := os.Symlink(f.target, alias); err != nil {
		t.Skipf("cannot create symlink: %v", err)
	}
	f.writeConfig("")
	body := strings.Replace(readFile(t, f.cfgPath), `"work_dir": "../build"`, fmt.Sprintf(`"work_dir": %q`, alias), 1)
	writeFile(t, f.cfgPath, body)
	if code, _, stderr := f.run(t, "--config", f.cfgPath, "--sync-only", "--dry-run"); code != ExitUsage {
		t.Fatalf("a work_dir aliasing the target must be rejected: %d %s", code, stderr)
	}
}

func TestWeaselDeploySuccessExitIsNotTrusted(t *testing.T) {
	f := newFixture(t)
	f.writeConfig("", f.weaselFrontend("deploy-ok", "log-sync-ok"))
	code, _, stderr := f.run(t, "--config", f.cfgPath)
	if code != ExitFailure {
		t.Fatalf("a Weasel deploy with exit 0 must not count as success: %d %s", code, stderr)
	}
	if got := f.eventList(); strings.Join(got, ",") != "deploy-ok" {
		t.Fatalf("no sync may follow an unverified deploy: %v", got)
	}
}

func TestWeaselSyncUsesLog(t *testing.T) {
	f := newFixture(t)
	f.writeConfig("", f.weaselFrontend("deploy-ok", "log-sync-ok"))
	if code, _, stderr := f.run(t, "--config", f.cfgPath, "--no-redeploy"); code != ExitOK {
		t.Fatalf("a logged Weasel sync must succeed: %s", stderr)
	}
	f2 := newFixture(t)
	f2.writeConfig("", f2.weaselFrontend("deploy-ok", "log-sync-fail"))
	code, _, stderr := f2.run(t, "--config", f2.cfgPath, "--no-redeploy")
	if code != ExitFailure || !strings.Contains(stderr, "0 success, 3 failure") {
		t.Fatalf("a failed task summary must fail despite exit 0: %d %s", code, stderr)
	}
}

func TestSecondFrontendInvalidLayerFailsBeforeSideEffects(t *testing.T) {
	f := newFixture(t)
	writeFile(t, filepath.Join(f.cfgDir, "frontends", "weasel", "helper.sh"), "#!/bin/sh\n")
	f.writeConfig("", f.squirrel("deploy-ok", "sync-ok"), fmt.Sprintf(`{
      "name": "weasel",
      "kind": "weasel",
      "active": true,
      "target_dir": %q,
      "ui_layer": "frontends/weasel"
    }`, filepath.Join(f.root, "target2")))
	code, _, stderr := f.run(t, "--config", f.cfgPath, "--no-redeploy", "--no-sync")
	if code != ExitUsage {
		t.Fatalf("an invalid layer of a later frontend must fail before side effects: %d %s", code, stderr)
	}
	f.noSideEffects(t)
	if _, err := os.Stat(filepath.Join(f.root, "target2", "default.yaml")); err == nil {
		t.Fatal("the second target was written")
	}
}

func TestMissingConfigFails(t *testing.T) {
	f := newFixture(t)
	if code, _, stderr := f.run(t, "--config", filepath.Join(f.root, "nope.json")); code != ExitUsage {
		t.Fatalf("exit = %d, want %d: %s", code, ExitUsage, stderr)
	}
}

func TestVersionFlag(t *testing.T) {
	f := newFixture(t)
	code, stdout, _ := f.run(t, "--version")
	if code != ExitOK || !strings.Contains(stdout, Version) {
		t.Fatalf("--version output: %d %q", code, stdout)
	}
}

func TestDeleteRemovesStaleFilesAndKeepsUserData(t *testing.T) {
	f := newFixture(t)
	f.writeConfig("")
	writeFile(t, filepath.Join(f.target, "stale.yaml"), "stale\n")
	writeFile(t, filepath.Join(f.target, "custom", "retired.custom.yaml"), "kept\n")
	if code, _, stderr := f.run(t, "--config", f.cfgPath, "--no-redeploy", "--no-sync"); code != ExitOK {
		t.Fatalf("update: %s", stderr)
	}
	if _, err := os.Stat(filepath.Join(f.target, "stale.yaml")); err != nil {
		t.Fatalf("nothing may be deleted without --delete: %v", err)
	}
	if code, _, stderr := f.run(t, "--config", f.cfgPath, "--no-redeploy", "--no-sync", "--delete"); code != ExitOK {
		t.Fatalf("--delete: %s", stderr)
	}
	if _, err := os.Stat(filepath.Join(f.target, "stale.yaml")); !os.IsNotExist(err) {
		t.Fatalf("--delete must remove stale files: %v", err)
	}
	for _, keep := range []string{"custom_phrase_user.dict.yaml", "custom/retired.custom.yaml", "installation.yaml", "user.yaml", "wanxiang.userdb"} {
		if _, err := os.Stat(filepath.Join(f.target, filepath.FromSlash(keep))); err != nil {
			t.Fatalf("--delete removed %s: %v", keep, err)
		}
	}
}
