package update

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func zipBytes(t *testing.T, files map[string][]byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	w := zip.NewWriter(&buf)
	names := make([]string, 0, len(files))
	for name := range files {
		names = append(names, name)
	}
	for _, name := range names {
		f, err := w.Create(name)
		if err != nil {
			t.Fatalf("create zip entry %s: %v", name, err)
		}
		if _, err := f.Write(files[name]); err != nil {
			t.Fatalf("write zip entry %s: %v", name, err)
		}
	}
	if err := w.Close(); err != nil {
		t.Fatalf("close zip: %v", err)
	}
	return buf.Bytes()
}

type fakeUpstream struct {
	t  *testing.T
	mu sync.Mutex

	server *httptest.Server

	assets    map[string][]byte
	releases  map[string][]map[string]any
	downloads int
	apiCalls  int
	authSeen  []string
	failAsset map[string]bool
}

func newFakeUpstream(t *testing.T) *fakeUpstream {
	t.Helper()
	f := &fakeUpstream{
		t:         t,
		assets:    map[string][]byte{},
		releases:  map[string][]map[string]any{},
		failAsset: map[string]bool{},
	}
	f.server = httptest.NewServer(http.HandlerFunc(f.handle))
	t.Cleanup(f.server.Close)
	return f
}

func (f *fakeUpstream) handle(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if strings.HasPrefix(r.URL.Path, "/repos/") {
		f.apiCalls++
		f.authSeen = append(f.authSeen, r.Header.Get("Authorization"))
		repo := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/repos/"), "/releases")
		rels, ok := f.releases[repo]
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(rels)
		return
	}
	name := strings.TrimPrefix(r.URL.Path, "/dl/")
	if f.failAsset[name] {
		http.Error(w, "boom", http.StatusInternalServerError)
		return
	}
	data, ok := f.assets[name]
	if !ok {
		http.NotFound(w, r)
		return
	}
	f.downloads++
	w.Header().Set("Content-Type", "application/octet-stream")
	_, _ = w.Write(data)
}

func (f *fakeUpstream) assetURL(name string) string { return f.server.URL + "/dl/" + name }

func (f *fakeUpstream) publish(repo, tag string, created time.Time, assets ...map[string]any) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.releases[repo] = append([]map[string]any{{
		"tag_name":   tag,
		"draft":      false,
		"created_at": created.UTC().Format(time.RFC3339),
		"assets":     assets,
	}}, f.releases[repo]...)
}

func (f *fakeUpstream) asset(name string, updated time.Time) map[string]any {
	return map[string]any{
		"name":                 name,
		"size":                 len(f.assets[name]),
		"updated_at":           updated.UTC().Format(time.RFC3339),
		"browser_download_url": f.assetURL(name),
	}
}

func (f *fakeUpstream) setAsset(name string, data []byte) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.assets[name] = data
}

func (f *fakeUpstream) stats() (downloads, apiCalls int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.downloads, f.apiCalls
}

// standardUpstream publishes the three resources used by the tool.
func standardUpstream(t *testing.T) *fakeUpstream {
	t.Helper()
	f := newFakeUpstream(t)
	f.setAsset("rime-wanxiang-base.zip", zipBytes(t, map[string][]byte{
		"default.yaml":                []byte("config_version: 1\n"),
		"wanxiang.schema.yaml":        []byte("schema_id: wanxiang\n"),
		"dicts/en.dict.yaml":          []byte("upstream-en\n"),
		"custom/wanxiang.custom.yaml": []byte("patch: {}\n"),
		"lua/wanxiang/librime.lua":    []byte("-- lua\n"),
	}))
	f.setAsset("base-dicts.zip", zipBytes(t, map[string][]byte{
		"en.dict.yaml": []byte("dict-en\n"),
		"zi.dict.yaml": []byte("dict-zi\n"),
	}))
	f.setAsset(ModelAssetName, []byte("gram-data"))
	f.publish("amzxyz/rime-wanxiang", "v1.2.3", time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC),
		f.asset("rime-wanxiang-base.zip", time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)))
	f.publish("amzxyz/rime-wanxiang", "dict-nightly", time.Date(2026, 1, 2, 0, 0, 0, 0, time.UTC),
		f.asset("base-dicts.zip", time.Date(2026, 1, 2, 0, 0, 0, 0, time.UTC)))
	f.publish("amzxyz/rime-wanxiang-data", "LTS", time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC),
		f.asset(ModelAssetName, time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)))
	return f
}

func fetchOptions(t *testing.T, f *fakeUpstream, work string, noDownload bool) FetchOptions {
	t.Helper()
	o := FetchOptions{WorkDir: work, NoDownload: noDownload}
	if !noDownload {
		o.Client = NewClient(f.server.URL, "")
	}
	return o
}

func TestEnsureFirstUpdate(t *testing.T) {
	f := standardUpstream(t)
	work := t.TempDir()
	layout, statuses, err := Ensure(context.Background(), fetchOptions(t, f, work, false))
	if err != nil {
		t.Fatalf("Ensure: %v", err)
	}
	if len(statuses) != 3 {
		t.Fatalf("status count = %d, want 3", len(statuses))
	}
	for _, st := range statuses {
		if st.Action != ActionDownloaded {
			t.Fatalf("resource %s action = %q, want %q", st.Resource, st.Action, ActionDownloaded)
		}
	}
	read := func(p string) string {
		t.Helper()
		data, err := os.ReadFile(p)
		if err != nil {
			t.Fatalf("read %s: %v", p, err)
		}
		return string(data)
	}
	if got := read(filepath.Join(layout.BaseDir, "default.yaml")); got != "config_version: 1\n" {
		t.Fatalf("base/default.yaml = %q", got)
	}
	if got := read(filepath.Join(layout.BaseDir, "dicts", "en.dict.yaml")); got != "upstream-en\n" {
		t.Fatalf("base/dicts/en.dict.yaml = %q", got)
	}
	if got := read(filepath.Join(layout.DictsDir, "en.dict.yaml")); got != "dict-en\n" {
		t.Fatalf("dicts/en.dict.yaml = %q", got)
	}
	if got := read(filepath.Join(layout.DictsDir, "zi.dict.yaml")); got != "dict-zi\n" {
		t.Fatalf("dicts/zi.dict.yaml = %q", got)
	}
	if got := read(layout.ModelFile); got != "gram-data" {
		t.Fatalf("model = %q", got)
	}
	if statuses[0].Version != "v1.2.3" {
		t.Fatalf("base version = %q, want tag", statuses[0].Version)
	}
	if statuses[1].Version != "2026-01-02T00:00:00Z" {
		t.Fatalf("dicts version = %q, want asset updated_at", statuses[1].Version)
	}
}

func TestEnsureReusesUnchangedResources(t *testing.T) {
	f := standardUpstream(t)
	work := t.TempDir()
	if _, _, err := Ensure(context.Background(), fetchOptions(t, f, work, false)); err != nil {
		t.Fatalf("first Ensure: %v", err)
	}
	downloads, _ := f.stats()
	_, statuses, err := Ensure(context.Background(), fetchOptions(t, f, work, false))
	if err != nil {
		t.Fatalf("second Ensure: %v", err)
	}
	for _, st := range statuses {
		if st.Action != ActionReused {
			t.Fatalf("resource %s must be reused, got %q", st.Resource, st.Action)
		}
	}
	afterDownloads, _ := f.stats()
	if afterDownloads != downloads {
		t.Fatalf("a repeated run downloaded: %d -> %d", downloads, afterDownloads)
	}
}

func TestEnsureAssetUpdateUnderSameTag(t *testing.T) {
	f := standardUpstream(t)
	work := t.TempDir()
	if _, _, err := Ensure(context.Background(), fetchOptions(t, f, work, false)); err != nil {
		t.Fatalf("first Ensure: %v", err)
	}
	// Same LTS tag, newer asset timestamp and content.
	f.setAsset(ModelAssetName, []byte("gram-data-v2"))
	f.publish("amzxyz/rime-wanxiang-data", "LTS", time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC),
		f.asset(ModelAssetName, time.Date(2026, 2, 1, 0, 0, 0, 0, time.UTC)))
	layout, statuses, err := Ensure(context.Background(), fetchOptions(t, f, work, false))
	if err != nil {
		t.Fatalf("Ensure: %v", err)
	}
	if statuses[2].Action != ActionDownloaded {
		t.Fatalf("the model must be downloaded again, got %q", statuses[2].Action)
	}
	data, err := os.ReadFile(layout.ModelFile)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "gram-data-v2" {
		t.Fatalf("model not updated: %q", data)
	}
	if statuses[0].Action != ActionReused || statuses[1].Action != ActionReused {
		t.Fatalf("other resources must not be downloaded again: %+v", statuses)
	}
}

func TestEnsureRestoresFromCacheWithoutNetwork(t *testing.T) {
	f := standardUpstream(t)
	work := t.TempDir()
	layout, _, err := Ensure(context.Background(), fetchOptions(t, f, work, false))
	if err != nil {
		t.Fatalf("first Ensure: %v", err)
	}
	if err := os.RemoveAll(layout.BaseDir); err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(layout.DictsDir); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(layout.ModelFile); err != nil {
		t.Fatal(err)
	}
	downloads, _ := f.stats()
	layout, statuses, err := Ensure(context.Background(), fetchOptions(t, f, work, true))
	if err != nil {
		t.Fatalf("--no-download restore: %v", err)
	}
	for _, st := range statuses {
		if st.Action != ActionRestored {
			t.Fatalf("resource %s must be restored, got %q", st.Resource, st.Action)
		}
	}
	if _, err := os.Stat(filepath.Join(layout.BaseDir, "default.yaml")); err != nil {
		t.Fatalf("base not restored: %v", err)
	}
	if _, err := os.Stat(filepath.Join(layout.DictsDir, "zi.dict.yaml")); err != nil {
		t.Fatalf("dictionaries not restored: %v", err)
	}
	if after, _ := f.stats(); after != downloads {
		t.Fatalf("--no-download downloaded: %d -> %d", downloads, after)
	}
}

func TestEnsureNoDownloadWithoutCacheFails(t *testing.T) {
	f := standardUpstream(t)
	work := t.TempDir()
	_, _, err := Ensure(context.Background(), fetchOptions(t, f, work, true))
	if err == nil {
		t.Fatal("--no-download without cache must fail")
	}
	if !strings.Contains(err.Error(), "no-download") {
		t.Fatalf("the error must mention --no-download: %v", err)
	}
}

func TestEnsureMissingAssetFails(t *testing.T) {
	f := newFakeUpstream(t)
	f.publish("amzxyz/rime-wanxiang", "v9.0.0", time.Now(),
		f.asset("some-other.zip", time.Now()))
	_, _, err := Ensure(context.Background(), fetchOptions(t, f, t.TempDir(), false))
	if err == nil || !strings.Contains(err.Error(), "has no asset") {
		t.Fatalf("a missing asset must fail: %v", err)
	}
}

func TestEnsureHTTPErrorKeepsPreviousContent(t *testing.T) {
	f := standardUpstream(t)
	work := t.TempDir()
	layout, _, err := Ensure(context.Background(), fetchOptions(t, f, work, false))
	if err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(filepath.Join(layout.BaseDir, "default.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	// New base release that fails to download.
	f.setAsset("rime-wanxiang-base.zip", []byte("new-content"))
	f.publish("amzxyz/rime-wanxiang", "v1.3.0", time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC),
		f.asset("rime-wanxiang-base.zip", time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC)))
	f.mu.Lock()
	f.failAsset["rime-wanxiang-base.zip"] = true
	f.mu.Unlock()

	if _, _, err := Ensure(context.Background(), fetchOptions(t, f, work, false)); err == nil {
		t.Fatal("a failed download must return an error")
	}
	after, err := os.ReadFile(filepath.Join(layout.BaseDir, "default.yaml"))
	if err != nil {
		t.Fatalf("previous content must survive a failure: %v", err)
	}
	if !bytes.Equal(before, after) {
		t.Fatalf("previous content changed after a failure: %q -> %q", before, after)
	}
}

func TestEnsureBadZipIsRejected(t *testing.T) {
	f := standardUpstream(t)
	work := t.TempDir()
	layout, _, err := Ensure(context.Background(), fetchOptions(t, f, work, false))
	if err != nil {
		t.Fatal(err)
	}
	f.setAsset("rime-wanxiang-base.zip", []byte("not a zip"))
	f.publish("amzxyz/rime-wanxiang", "v2.0.0", time.Date(2026, 4, 1, 0, 0, 0, 0, time.UTC),
		f.asset("rime-wanxiang-base.zip", time.Date(2026, 4, 1, 0, 0, 0, 0, time.UTC)))
	if _, _, err := Ensure(context.Background(), fetchOptions(t, f, work, false)); err == nil {
		t.Fatal("a corrupt ZIP must fail")
	}
	if _, err := os.Stat(filepath.Join(layout.BaseDir, "default.yaml")); err != nil {
		t.Fatalf("previous content must survive a corrupt ZIP: %v", err)
	}
}

func TestEnsureRejectsZipTraversal(t *testing.T) {
	f := standardUpstream(t)
	f.setAsset("rime-wanxiang-base.zip", zipBytes(t, map[string][]byte{
		"../escape.yaml": []byte("bad"),
	}))
	f.publish("amzxyz/rime-wanxiang", "v3.0.0", time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC),
		f.asset("rime-wanxiang-base.zip", time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC)))
	work := t.TempDir()
	_, _, err := Ensure(context.Background(), fetchOptions(t, f, work, false))
	if err == nil {
		t.Fatal("ZIP traversal must fail")
	}
	if _, statErr := os.Stat(filepath.Join(work, "escape.yaml")); statErr == nil {
		t.Fatal("a traversal entry was written")
	}
	if _, statErr := os.Stat(filepath.Join(filepath.Dir(work), "escape.yaml")); statErr == nil {
		t.Fatal("a traversal entry was written outside the workspace")
	}
}

func TestEnsureEmptyZipKeepsPreviousContent(t *testing.T) {
	f := standardUpstream(t)
	work := t.TempDir()
	layout, _, err := Ensure(context.Background(), fetchOptions(t, f, work, false))
	if err != nil {
		t.Fatal(err)
	}
	before := readTestFile(t, filepath.Join(layout.BaseDir, "default.yaml"))
	f.setAsset("rime-wanxiang-base.zip", zipBytes(t, map[string][]byte{"only-dir/": {}}))
	f.publish("amzxyz/rime-wanxiang", "v4.0.0", time.Date(2026, 7, 1, 0, 0, 0, 0, time.UTC),
		f.asset("rime-wanxiang-base.zip", time.Date(2026, 7, 1, 0, 0, 0, 0, time.UTC)))
	if _, _, err := Ensure(context.Background(), fetchOptions(t, f, work, false)); err == nil {
		t.Fatal("an empty ZIP must be rejected")
	}
	if got := readTestFile(t, filepath.Join(layout.BaseDir, "default.yaml")); got != before {
		t.Fatalf("previous content must survive an empty ZIP: %q", got)
	}
	m, err := readMarker(cacheFor(work, Specs[0]).marker)
	if err != nil {
		t.Fatal(err)
	}
	if m.Version != "v1.2.3" {
		t.Fatalf("the marker must not advance after a failure: %q", m.Version)
	}
}

func TestEnsureRejectsSymlinkedPayloadDir(t *testing.T) {
	f := standardUpstream(t)
	work := t.TempDir()
	outside := t.TempDir()
	payloadParent := filepath.Join(work, "cache", ResourceBase)
	if err := os.MkdirAll(payloadParent, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(payloadParent, "payload")); err != nil {
		t.Skipf("cannot create symlink: %v", err)
	}
	if _, _, err := Ensure(context.Background(), fetchOptions(t, f, work, false)); err == nil {
		t.Fatal("a symlinked payload directory must be rejected")
	}
	entries, err := os.ReadDir(outside)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("wrote outside through a symlink: %v", entries)
	}
}

func TestEnsureRejectsFlatCollision(t *testing.T) {
	f := standardUpstream(t)
	f.setAsset("base-dicts.zip", zipBytes(t, map[string][]byte{
		"a/en.dict.yaml": []byte("one"),
		"b/en.dict.yaml": []byte("two"),
	}))
	f.publish("amzxyz/rime-wanxiang", "dict-nightly", time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC),
		f.asset("base-dicts.zip", time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)))
	_, _, err := Ensure(context.Background(), fetchOptions(t, f, t.TempDir(), false))
	if err == nil || !strings.Contains(err.Error(), "collision") {
		t.Fatalf("a flattening collision must fail: %v", err)
	}
}

func TestEnsureStripsSingleTopDirectory(t *testing.T) {
	f := standardUpstream(t)
	f.setAsset("rime-wanxiang-base.zip", zipBytes(t, map[string][]byte{
		"wrapper/default.yaml": []byte("wrapped\n"),
	}))
	work := t.TempDir()
	layout, _, err := Ensure(context.Background(), fetchOptions(t, f, work, false))
	if err != nil {
		t.Fatalf("Ensure: %v", err)
	}
	if _, err := os.Stat(filepath.Join(layout.BaseDir, "default.yaml")); err != nil {
		t.Fatalf("the single top-level directory must be stripped: %v", err)
	}
}

func TestTokenIsSentToAPIAndNotLogged(t *testing.T) {
	f := standardUpstream(t)
	work := t.TempDir()
	o := fetchOptions(t, f, work, false)
	o.Client.Token = "ghp_secret_value"
	var logs bytes.Buffer
	o.Log = &logs
	if _, _, err := Ensure(context.Background(), o); err != nil {
		t.Fatalf("Ensure: %v", err)
	}
	f.mu.Lock()
	auth := append([]string(nil), f.authSeen...)
	f.mu.Unlock()
	if len(auth) == 0 || auth[0] != "Bearer ghp_secret_value" {
		t.Fatalf("API request without token: %v", auth)
	}
	if strings.Contains(logs.String(), "ghp_secret_value") {
		t.Fatalf("the log leaked the token: %s", logs.String())
	}
	if strings.Contains(logs.String(), "?") {
		t.Fatalf("the log must not contain the query string: %s", logs.String())
	}
}

func TestSelectReleasePrefersNewestVersion(t *testing.T) {
	f := newFakeUpstream(t)
	f.setAsset("rime-wanxiang-base.zip", zipBytes(t, map[string][]byte{"a.yaml": []byte("a")}))
	for _, tag := range []string{"v1.9.0", "v1.10.0", "v2.0.0-beta"} {
		f.publish("amzxyz/rime-wanxiang", tag, time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC),
			f.asset("rime-wanxiang-base.zip", time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)))
	}
	sel, err := selectRelease(context.Background(), NewClient(f.server.URL, ""), Specs[0])
	if err != nil {
		t.Fatalf("selectRelease: %v", err)
	}
	if sel.Version != "v2.0.0-beta" {
		t.Fatalf("the highest version must be selected, got %q", sel.Version)
	}
}

func TestPayloadIntactDetectsTampering(t *testing.T) {
	work := t.TempDir()
	cache := cacheFor(work, Specs[0])
	if err := os.MkdirAll(filepath.Dir(cache.payload), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cache.payload, []byte("data"), 0o644); err != nil {
		t.Fatal(err)
	}
	// Independent oracle: SHA-256 of "data".
	const dataSHA = "3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7"
	m := marker{Version: "v1", Size: 4, SHA256: dataSHA}
	if !payloadIntact(cache, m) {
		t.Fatal("an untouched payload must be valid")
	}
	// Same length, different content: only the digest can catch it.
	if err := os.WriteFile(cache.payload, []byte("datb"), 0o644); err != nil {
		t.Fatal(err)
	}
	if payloadIntact(cache, m) {
		t.Fatal("a same-size tampered payload must be invalid")
	}
	if err := os.WriteFile(cache.payload, []byte("dat"), 0o644); err != nil {
		t.Fatal(err)
	}
	if payloadIntact(cache, m) {
		t.Fatal("a truncated payload must be invalid")
	}
}

func TestAdoptRejectsUnknownResource(t *testing.T) {
	if err := adoptPayload(Spec{Name: "unknown"}, "x", Layout{}, t.TempDir()); err == nil {
		t.Fatal("an unknown resource must fail")
	}
}
