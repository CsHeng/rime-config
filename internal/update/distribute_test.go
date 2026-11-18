package update

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func makeStage(t *testing.T, files map[string]string, seeds map[string]bool) *Stage {
	t.Helper()
	dir := t.TempDir()
	s := &Stage{Dir: dir}
	for rel, content := range files {
		writeTestFile(t, filepath.Join(dir, filepath.FromSlash(rel)), content)
		class := Managed
		if seeds[rel] {
			class = Seed
		}
		s.Files = append(s.Files, File{Rel: rel, Class: class})
	}
	return s
}

func syncOnce(t *testing.T, s *Stage, target string, protect Protect, del, dryRun bool, out *bytes.Buffer) (*SyncResult, error) {
	t.Helper()
	if out == nil {
		out = &bytes.Buffer{}
	}
	return SyncTarget(context.Background(), SyncOptions{
		Stage: s, TargetDir: target, Protect: protect,
		Delete: del, DryRun: dryRun, Out: out,
	})
}

func exists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

func TestSyncCopiesAndIsIdempotent(t *testing.T) {
	s := makeStage(t, map[string]string{
		"default.yaml":       "v1\n",
		"dicts/en.dict.yaml": "dict\n",
		"中文 目录/短语.yaml":      "phrase\n",
	}, nil)
	target := t.TempDir()
	protect := Protect{PhraseFile: "custom_phrase_user.dict.yaml"}

	res, err := syncOnce(t, s, target, protect, false, false, nil)
	if err != nil {
		t.Fatalf("first sync: %v", err)
	}
	if len(res.Copied) != 3 || len(res.Updated) != 0 {
		t.Fatalf("first sync must create 3 files: copied=%v updated=%v", res.Copied, res.Updated)
	}
	if got := readTestFile(t, filepath.Join(target, "中文 目录", "短语.yaml")); got != "phrase\n" {
		t.Fatalf("non-ASCII path with spaces not copied: %q", got)
	}
	// Pin an old mtime so a rewrite would be visible on any filesystem.
	old := time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)
	if err := os.Chtimes(filepath.Join(target, "default.yaml"), old, old); err != nil {
		t.Fatal(err)
	}

	res, err = syncOnce(t, s, target, protect, false, false, nil)
	if err != nil {
		t.Fatalf("second sync: %v", err)
	}
	if len(res.Copied) != 0 || len(res.Skipped) != 3 {
		t.Fatalf("an unchanged run must not rewrite: copied=%v skipped=%v", res.Copied, res.Skipped)
	}
	info, err := os.Stat(filepath.Join(target, "default.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if !info.ModTime().Equal(old) {
		t.Fatalf("unchanged file was rewritten: mtime %v", info.ModTime())
	}
}

func TestExistingDifferentFilesAreReportedAsReplaced(t *testing.T) {
	s := makeStage(t, map[string]string{
		"wanxiang.custom.yaml": "repository\n",
		"new.yaml":             "new\n",
	}, nil)
	target := t.TempDir()
	writeTestFile(t, filepath.Join(target, "wanxiang.custom.yaml"), "hand written on the device\n")

	var plan bytes.Buffer
	res, err := syncOnce(t, s, target, Protect{}, false, true, &plan)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(plan.String(), "update wanxiang.custom.yaml") || !strings.Contains(plan.String(), "copy   new.yaml") {
		t.Fatalf("dry-run must distinguish replacing an existing file from creating one:\n%s", plan.String())
	}
	if len(res.Updated) != 1 || res.Updated[0] != "wanxiang.custom.yaml" {
		t.Fatalf("Updated = %v, want [wanxiang.custom.yaml]", res.Updated)
	}
	if got := readTestFile(t, filepath.Join(target, "wanxiang.custom.yaml")); got != "hand written on the device\n" {
		t.Fatalf("dry-run wrote the target: %q", got)
	}
}

func TestSeedFilesAreOnlyCreatedWhenMissing(t *testing.T) {
	s := makeStage(t, map[string]string{
		"custom/wanxiang.custom.yaml":  "seed\n",
		"custom_phrase_user.dict.yaml": "template\n",
	}, map[string]bool{"custom/wanxiang.custom.yaml": true, "custom_phrase_user.dict.yaml": true})
	target := t.TempDir()
	protect := Protect{PhraseFile: "custom_phrase_user.dict.yaml"}

	if _, err := syncOnce(t, s, target, protect, false, false, nil); err != nil {
		t.Fatalf("first sync: %v", err)
	}
	if got := readTestFile(t, filepath.Join(target, "custom", "wanxiang.custom.yaml")); got != "seed\n" {
		t.Fatalf("seed must be created once: %q", got)
	}
	writeTestFile(t, filepath.Join(target, "custom", "wanxiang.custom.yaml"), "user-edit\n")
	writeTestFile(t, filepath.Join(target, "custom_phrase_user.dict.yaml"), "my phrases\n")

	res, err := syncOnce(t, s, target, protect, true, false, nil)
	if err != nil {
		t.Fatalf("second sync: %v", err)
	}
	if got := readTestFile(t, filepath.Join(target, "custom", "wanxiang.custom.yaml")); got != "user-edit\n" {
		t.Fatalf("seed was overwritten: %q", got)
	}
	if got := readTestFile(t, filepath.Join(target, "custom_phrase_user.dict.yaml")); got != "my phrases\n" {
		t.Fatalf("user phrase file was overwritten: %q", got)
	}
	if len(res.Deleted) != 0 {
		t.Fatalf("seeds must not be deleted: %v", res.Deleted)
	}
}

func TestRetiredSeedsAreProtectedByPath(t *testing.T) {
	target := t.TempDir()
	writeTestFile(t, filepath.Join(target, "custom", "retired.custom.yaml"), "user-edited\n")
	writeTestFile(t, filepath.Join(target, "custom_phrase_user.dict.yaml"), "phrases\n")
	writeTestFile(t, filepath.Join(target, "stale.yaml"), "stale\n")
	s := makeStage(t, map[string]string{"default.yaml": "x\n"}, nil)

	res, err := syncOnce(t, s, target, Protect{PhraseFile: "custom_phrase_user.dict.yaml"}, true, false, nil)
	if err != nil {
		t.Fatal(err)
	}
	if got := readTestFile(t, filepath.Join(target, "custom", "retired.custom.yaml")); got != "user-edited\n" {
		t.Fatalf("a seed whose source disappeared must stay: %q", got)
	}
	if !exists(filepath.Join(target, "custom_phrase_user.dict.yaml")) {
		t.Fatal("the user phrase file must never be deleted")
	}
	if exists(filepath.Join(target, "stale.yaml")) || len(res.Deleted) != 1 {
		t.Fatalf("only stale.yaml must be deleted: %v", res.Deleted)
	}
}

func TestManagedPhraseFileOverwritesTarget(t *testing.T) {
	// A repository master: the stage carries the phrase file as managed and
	// the caller does not protect it.
	s := makeStage(t, map[string]string{"custom_phrase_user.dict.yaml": "repository master\n"}, nil)
	target := t.TempDir()
	writeTestFile(t, filepath.Join(target, "custom_phrase_user.dict.yaml"), "older device copy\n")
	res, err := syncOnce(t, s, target, Protect{}, false, false, nil)
	if err != nil {
		t.Fatal(err)
	}
	if got := readTestFile(t, filepath.Join(target, "custom_phrase_user.dict.yaml")); got != "repository master\n" {
		t.Fatalf("managed phrase file must replace the target copy: %q", got)
	}
	if len(res.Updated) != 1 {
		t.Fatalf("replacement must be reported: %v", res.Updated)
	}
}

func TestCoreProtectedStateIsNeverWritten(t *testing.T) {
	s := makeStage(t, map[string]string{
		"user.yaml":                   "staged-user\n",
		"installation.yaml":           "staged-install\n",
		"build/default.yaml":          "staged-build\n",
		"wanxiang.userdb/data.ldb":    "staged-db\n",
		"nested/tips.userdb/data.ldb": "staged-db2\n",
		"sync/wanxiang.userdb.txt":    "staged-snapshot\n",
		"default.yaml":                "config\n",
	}, nil)
	target := t.TempDir()
	writeTestFile(t, filepath.Join(target, "user.yaml"), "user\n")
	writeTestFile(t, filepath.Join(target, "installation.yaml"), "install\n")
	writeTestFile(t, filepath.Join(target, "wanxiang.userdb", "data.ldb"), "user-db\n")
	writeTestFile(t, filepath.Join(target, "sync", "wanxiang.userdb.txt"), "snapshot\n")

	res, err := syncOnce(t, s, target, Protect{}, true, false, nil)
	if err != nil {
		t.Fatalf("sync: %v", err)
	}
	for rel, want := range map[string]string{
		"user.yaml":                "user\n",
		"installation.yaml":        "install\n",
		"wanxiang.userdb/data.ldb": "user-db\n",
		"sync/wanxiang.userdb.txt": "snapshot\n",
	} {
		if got := readTestFile(t, filepath.Join(target, filepath.FromSlash(rel))); got != want {
			t.Fatalf("%s was overwritten: %q", rel, got)
		}
	}
	if exists(filepath.Join(target, "build")) {
		t.Fatal("protected build/ must not be created")
	}
	if len(res.Kept) != 6 {
		t.Fatalf("all protected entries must be kept: %v", res.Kept)
	}
	if len(res.Deleted) != 0 {
		t.Fatalf("protected entries must not be deleted: %v", res.Deleted)
	}
}

func TestDeleteRemovesOnlyUnprotectedEntries(t *testing.T) {
	s := makeStage(t, map[string]string{"default.yaml": "v2\n"}, nil)
	target := t.TempDir()
	writeTestFile(t, filepath.Join(target, "default.yaml"), "v1\n")
	writeTestFile(t, filepath.Join(target, "old.yaml"), "old\n")
	writeTestFile(t, filepath.Join(target, "empty", "sub", "old.yaml"), "old\n")
	writeTestFile(t, filepath.Join(target, "lua", "mine.lua"), "-- mine\n")
	writeTestFile(t, filepath.Join(target, "tips", "note.txt"), "tip\n")
	writeTestFile(t, filepath.Join(target, "custom_phrase_user.dict.yaml"), "mine\n")
	writeTestFile(t, filepath.Join(target, "custom", "user-note.custom.yaml"), "note\n")
	writeTestFile(t, filepath.Join(target, "keep", "user.yaml"), "user\n")
	writeTestFile(t, filepath.Join(target, "keep", "old.yaml"), "old\n")
	protect := Protect{PhraseFile: "custom_phrase_user.dict.yaml"}

	if _, err := syncOnce(t, s, target, protect, false, false, nil); err != nil {
		t.Fatalf("sync: %v", err)
	}
	if !exists(filepath.Join(target, "old.yaml")) {
		t.Fatal("nothing may be deleted without --delete")
	}

	res, err := syncOnce(t, s, target, protect, true, false, nil)
	if err != nil {
		t.Fatalf("sync --delete: %v", err)
	}
	if exists(filepath.Join(target, "old.yaml")) {
		t.Fatal("old.yaml must be deleted")
	}
	if exists(filepath.Join(target, "empty")) {
		t.Fatal("empty directories must be pruned")
	}
	for _, keep := range []string{
		filepath.Join("lua", "mine.lua"),
		filepath.Join("tips", "note.txt"),
		"custom_phrase_user.dict.yaml",
		filepath.Join("custom", "user-note.custom.yaml"),
		filepath.Join("keep", "user.yaml"),
	} {
		if !exists(filepath.Join(target, keep)) {
			t.Fatalf("%s must be kept", keep)
		}
	}
	if exists(filepath.Join(target, "keep", "old.yaml")) {
		t.Fatal("an unprotected old file next to a protected one must be deleted")
	}
	if len(res.Deleted) != 3 {
		t.Fatalf("Deleted = %v, want 3 entries", res.Deleted)
	}
}

func TestDeleteStopsOnCancellation(t *testing.T) {
	target := t.TempDir()
	writeTestFile(t, filepath.Join(target, "default.yaml"), "v\n")
	writeTestFile(t, filepath.Join(target, "stale.yaml"), "stale\n")
	stage := map[string]bool{"default.yaml": true}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	deleted, _, err := deleteMissing(ctx, target, stage, Protect{}, false, nil)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want context.Canceled", err)
	}
	if len(deleted) != 0 || !exists(filepath.Join(target, "stale.yaml")) {
		t.Fatalf("nothing may be deleted after cancellation: %v", deleted)
	}
}

func TestExcludePatternsSkipCopyAndDelete(t *testing.T) {
	s := makeStage(t, map[string]string{
		"default.yaml": "v2\n",
		"debug.log":    "staged\n",
	}, nil)
	target := t.TempDir()
	writeTestFile(t, filepath.Join(target, "old.log"), "old log\n")
	writeTestFile(t, filepath.Join(target, "sub", "a.log"), "old log\n")
	protect := Protect{Exclude: []string{"*.log"}}

	res, err := syncOnce(t, s, target, protect, true, false, nil)
	if err != nil {
		t.Fatalf("sync: %v", err)
	}
	if exists(filepath.Join(target, "debug.log")) {
		t.Fatal("an excluded file must not be copied")
	}
	if !exists(filepath.Join(target, "old.log")) || !exists(filepath.Join(target, "sub", "a.log")) {
		t.Fatal("excluded files must not be deleted")
	}
	if len(res.Kept) != 1 {
		t.Fatalf("Kept = %v, want [debug.log]", res.Kept)
	}
}

func TestSyncDryRunMakesNoChanges(t *testing.T) {
	s := makeStage(t, map[string]string{
		"default.yaml": "v2\n",
		"dir/new.yaml": "new\n",
	}, nil)
	target := t.TempDir()
	writeTestFile(t, filepath.Join(target, "default.yaml"), "v1\n")
	writeTestFile(t, filepath.Join(target, "old.yaml"), "old\n")

	var out bytes.Buffer
	res, err := syncOnce(t, s, target, Protect{}, true, true, &out)
	if err != nil {
		t.Fatalf("dry-run: %v", err)
	}
	if got := readTestFile(t, filepath.Join(target, "default.yaml")); got != "v1\n" {
		t.Fatalf("dry-run wrote a file: %q", got)
	}
	if exists(filepath.Join(target, "dir")) {
		t.Fatal("dry-run created a directory")
	}
	if !exists(filepath.Join(target, "old.yaml")) {
		t.Fatal("dry-run deleted a file")
	}
	plan := out.String()
	for _, want := range []string{"update default.yaml", "copy   dir/new.yaml", "delete old.yaml"} {
		if !strings.Contains(plan, want) {
			t.Fatalf("plan is missing %q:\n%s", want, plan)
		}
	}
	if len(res.Copied) != 2 || len(res.Deleted) != 1 {
		t.Fatalf("dry-run counts: %+v", res)
	}
}

func TestSyncDryRunDoesNotCreateMissingTarget(t *testing.T) {
	s := makeStage(t, map[string]string{"a.yaml": "a\n"}, nil)
	target := filepath.Join(t.TempDir(), "new-target")
	if _, err := syncOnce(t, s, target, Protect{}, false, true, nil); err != nil {
		t.Fatalf("dry-run: %v", err)
	}
	if exists(target) {
		t.Fatal("dry-run created the target directory")
	}
}

func TestSyncRejectsSymlinkEscape(t *testing.T) {
	s := makeStage(t, map[string]string{"a.yaml": "a\n"}, nil)
	outside := t.TempDir()
	target := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(target, "escape")); err != nil {
		t.Skipf("cannot create symlink: %v", err)
	}
	if _, err := syncOnce(t, s, target, Protect{}, false, false, nil); err == nil {
		t.Fatal("a symlink pointing outside the target must be rejected")
	}
	if exists(filepath.Join(target, "a.yaml")) {
		t.Fatal("nothing may be written after the rejection")
	}
}

func TestSyncRejectsWriteThroughSymlinkDir(t *testing.T) {
	outside := t.TempDir()
	target := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(target, "sub")); err != nil {
		t.Skipf("cannot create symlink: %v", err)
	}
	s := makeStage(t, map[string]string{"sub/b.yaml": "b\n"}, nil)
	if _, err := syncOnce(t, s, target, Protect{}, false, false, nil); err == nil {
		t.Fatal("writing through a symlinked directory must fail")
	}
	if exists(filepath.Join(outside, "b.yaml")) {
		t.Fatal("a file was written outside the target")
	}
}

func TestSyncReportsReadOnlyDirectory(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root ignores permissions")
	}
	s := makeStage(t, map[string]string{"ro/a.yaml": "a\n"}, nil)
	target := t.TempDir()
	ro := filepath.Join(target, "ro")
	if err := os.Mkdir(ro, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(ro, 0o755) })
	if _, err := syncOnce(t, s, target, Protect{}, false, false, nil); err == nil {
		t.Fatal("a read-only directory must return an error")
	}
}

func TestSyncRejectsOverlappingStageAndTarget(t *testing.T) {
	root := t.TempDir()
	stageDir := filepath.Join(root, "stage")
	writeTestFile(t, filepath.Join(stageDir, "a.yaml"), "a")
	s := &Stage{Dir: stageDir, Files: []File{{Rel: "a.yaml"}}}
	if _, err := syncOnce(t, s, root, Protect{}, false, false, nil); err == nil {
		t.Fatal("overlapping stage and target must be rejected")
	}
}

func TestNestedExclusionProtectsDescendants(t *testing.T) {
	s := makeStage(t, map[string]string{
		"nested/private/settings.yaml": "staged\n",
		"nested/other.yaml":            "other\n",
	}, nil)
	target := t.TempDir()
	writeTestFile(t, filepath.Join(target, "nested", "private", "settings.yaml"), "user\n")
	writeTestFile(t, filepath.Join(target, "nested", "private", "old.yaml"), "old\n")
	protect := Protect{Exclude: []string{"private"}}

	if _, err := syncOnce(t, s, target, protect, true, false, nil); err != nil {
		t.Fatalf("sync: %v", err)
	}
	if got := readTestFile(t, filepath.Join(target, "nested", "private", "settings.yaml")); got != "user\n" {
		t.Fatalf("a file below an excluded directory was overwritten: %q", got)
	}
	if !exists(filepath.Join(target, "nested", "private", "old.yaml")) {
		t.Fatal("a file below an excluded directory was deleted")
	}
	if got := readTestFile(t, filepath.Join(target, "nested", "other.yaml")); got != "other\n" {
		t.Fatalf("a file outside the exclusion must be distributed: %q", got)
	}
}

func TestCaseInsensitiveProtection(t *testing.T) {
	s := makeStage(t, map[string]string{
		"USER.YAML":            "staged\n",
		"Installation.yaml":    "staged\n",
		"Build/default.yaml":   "staged\n",
		"wanxiang.USERDB/data": "staged\n",
		"normal.yaml":          "normal\n",
	}, nil)
	target := t.TempDir()
	writeTestFile(t, filepath.Join(target, "user.yaml"), "user\n")
	writeTestFile(t, filepath.Join(target, "wanxiang.userdb", "data"), "db\n")

	if _, err := syncOnce(t, s, target, Protect{}, false, false, nil); err != nil {
		t.Fatalf("sync: %v", err)
	}
	if got := readTestFile(t, filepath.Join(target, "user.yaml")); got != "user\n" {
		t.Fatalf("protected file with different case was overwritten: %q", got)
	}
	if got := readTestFile(t, filepath.Join(target, "wanxiang.userdb", "data")); got != "db\n" {
		t.Fatalf("userdb with different case was overwritten: %q", got)
	}
	if got := readTestFile(t, filepath.Join(target, "normal.yaml")); got != "normal\n" {
		t.Fatalf("an ordinary file must be copied: %q", got)
	}
}

func TestCaseCollisionInStageRejected(t *testing.T) {
	s := makeStage(t, map[string]string{
		"a.yaml": "one\n",
		"A.yaml": "two\n",
	}, nil)
	if _, err := syncOnce(t, s, t.TempDir(), Protect{}, false, false, nil); err == nil {
		t.Fatal("stage paths differing only in case must be rejected")
	}
}

func TestMatchPattern(t *testing.T) {
	cases := []struct {
		pattern, rel string
		want         bool
	}{
		{"*.log", "debug.log", true},
		{"*.log", "sub/debug.log", true},
		{"build/", "build/default.yaml", true},
		{"build/", "build", true},
		{"dicts/*.yaml", "dicts/a.yaml", true},
		{"dicts/*.yaml", "other/a.yaml", false},
		{"custom", "custom/a.yaml", true},
		{"*.log", "debug.txt", false},
	}
	for _, tc := range cases {
		if got := matchPattern(tc.pattern, tc.rel); got != tc.want {
			t.Fatalf("matchPattern(%q, %q) = %v, want %v", tc.pattern, tc.rel, got, tc.want)
		}
	}
}
