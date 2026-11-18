package update

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func writeTestFile(t *testing.T, p, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func readTestFile(t *testing.T, p string) string {
	t.Helper()
	data, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("read %s: %v", p, err)
	}
	return string(data)
}

func testUpstream(t *testing.T, work string) Layout {
	t.Helper()
	up := upstreamLayout(work)
	writeTestFile(t, filepath.Join(up.BaseDir, "a.yaml"), "a")
	writeTestFile(t, filepath.Join(up.DictsDir, "d.dict.yaml"), "d")
	writeTestFile(t, up.ModelFile, "gram")
	return up
}

func classOf(t *testing.T, s *Stage, rel string) Class {
	t.Helper()
	f, ok := stageFile(s, rel)
	if !ok {
		t.Fatalf("stage is missing %s", rel)
	}
	return f.Class
}

func stageFile(s *Stage, rel string) (File, bool) {
	for _, f := range s.Files {
		if f.Rel == rel {
			return f, true
		}
	}
	return File{}, false
}

func TestBuildStageOverlayOrder(t *testing.T) {
	work := t.TempDir()
	up := upstreamLayout(work)
	writeTestFile(t, filepath.Join(up.BaseDir, "default.yaml"), "upstream")
	writeTestFile(t, filepath.Join(up.BaseDir, "dicts", "en.dict.yaml"), "upstream-dict")
	writeTestFile(t, filepath.Join(up.BaseDir, "custom", "wanxiang.custom.yaml"), "base-custom")
	writeTestFile(t, filepath.Join(up.BaseDir, "lua", "x.lua"), "-- lua")
	writeTestFile(t, filepath.Join(up.DictsDir, "en.dict.yaml"), "nightly-dict")
	writeTestFile(t, up.ModelFile, "gram")

	cfgRoot := t.TempDir()
	local := filepath.Join(cfgRoot, "local")
	common := filepath.Join(cfgRoot, "common")
	ui := filepath.Join(cfgRoot, "ui")
	writeTestFile(t, filepath.Join(local, "default.yaml"), "local")
	writeTestFile(t, filepath.Join(local, "local-only.yaml"), "local-only")
	writeTestFile(t, filepath.Join(common, "default.yaml"), "common")
	writeTestFile(t, filepath.Join(ui, "default.yaml"), "ui")

	target := t.TempDir()
	stageDir := filepath.Join(work, "stage", "squirrel")
	s, err := BuildStage(context.Background(), StageOptions{
		Layout:         up,
		LocalLayer:     local,
		CommonLayer:    common,
		UILayer:        ui,
		StageDir:       stageDir,
		TargetDir:      target,
		UserPhraseFile: "custom_phrase_user.dict.yaml",
	})
	if err != nil {
		t.Fatalf("BuildStage: %v", err)
	}
	if got := readTestFile(t, filepath.Join(stageDir, "default.yaml")); got != "ui" {
		t.Fatalf("overlay order: default.yaml = %q, want ui", got)
	}
	if got := readTestFile(t, filepath.Join(stageDir, "dicts", "en.dict.yaml")); got != "nightly-dict" {
		t.Fatalf("dictionaries must come from the nightly asset: %q", got)
	}
	if got := readTestFile(t, filepath.Join(stageDir, ModelAssetName)); got != "gram" {
		t.Fatalf("grammar model missing: %q", got)
	}
	if got := readTestFile(t, filepath.Join(stageDir, "local-only.yaml")); got != "local-only" {
		t.Fatalf("local layer file missing: %q", got)
	}
	if got := readTestFile(t, filepath.Join(stageDir, "custom", "wanxiang.custom.yaml")); got != "base-custom" {
		t.Fatalf("custom/ must keep the upstream content: %q", got)
	}
	if c := classOf(t, s, "custom/wanxiang.custom.yaml"); c != Seed {
		t.Fatalf("custom/ files must be seeds, got %v", c)
	}
	if c := classOf(t, s, "default.yaml"); c != Managed {
		t.Fatalf("default.yaml must be managed, got %v", c)
	}
	if _, ok := stageFile(s, "custom_phrase_user.dict.yaml"); ok {
		t.Fatal("without a template no phrase file may be invented")
	}
	if s.PhraseManaged {
		t.Fatal("no layer provides the phrase file")
	}
}

func TestBuildStageUserPhrase(t *testing.T) {
	const phrase = "custom_phrase_user.dict.yaml"
	work := t.TempDir()
	up := testUpstream(t, work)
	cfgRoot := t.TempDir()
	example := filepath.Join(cfgRoot, "custom_phrase_user.dict.yaml.example")
	writeTestFile(t, example, "template\n")

	t.Run("seeded from the template when the target has none", func(t *testing.T) {
		stageDir := filepath.Join(work, "stage", "a")
		s, err := BuildStage(context.Background(), StageOptions{
			Layout: up, StageDir: stageDir, TargetDir: t.TempDir(),
			UserPhraseFile: phrase, PhraseExample: example,
		})
		if err != nil {
			t.Fatal(err)
		}
		if got := readTestFile(t, filepath.Join(stageDir, phrase)); got != "template\n" {
			t.Fatalf("stage must use the template: %q", got)
		}
		if c := classOf(t, s, phrase); c != Seed || s.PhraseManaged {
			t.Fatalf("template copy must be a seed: class=%v managed=%v", c, s.PhraseManaged)
		}
	})

	t.Run("left alone when only the target has one", func(t *testing.T) {
		target := t.TempDir()
		writeTestFile(t, filepath.Join(target, phrase), "device phrases\n")
		s, err := BuildStage(context.Background(), StageOptions{
			Layout: up, StageDir: filepath.Join(work, "stage", "b"), TargetDir: target,
			UserPhraseFile: phrase, PhraseExample: example,
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, ok := stageFile(s, phrase); ok || s.PhraseManaged {
			t.Fatal("an unmanaged target phrase file must not be staged")
		}
	})

	t.Run("managed when the local layer provides it", func(t *testing.T) {
		local := filepath.Join(cfgRoot, "local")
		writeTestFile(t, filepath.Join(local, phrase), "repository master\n")
		target := t.TempDir()
		writeTestFile(t, filepath.Join(target, phrase), "older device copy\n")
		stageDir := filepath.Join(work, "stage", "c")
		s, err := BuildStage(context.Background(), StageOptions{
			Layout: up, LocalLayer: local, StageDir: stageDir, TargetDir: target,
			UserPhraseFile: phrase, PhraseExample: example,
		})
		if err != nil {
			t.Fatal(err)
		}
		if !s.PhraseManaged || classOf(t, s, phrase) != Managed {
			t.Fatalf("repository phrase file must be managed: managed=%v", s.PhraseManaged)
		}
		if got := readTestFile(t, filepath.Join(stageDir, phrase)); got != "repository master\n" {
			t.Fatalf("stage must carry the repository master: %q", got)
		}
	})
}

func TestBuildStageRejectsSymlinkLayer(t *testing.T) {
	work := t.TempDir()
	up := testUpstream(t, work)
	layer := t.TempDir()
	outside := filepath.Join(t.TempDir(), "outside.yaml")
	writeTestFile(t, outside, "outside")
	if err := os.Symlink(outside, filepath.Join(layer, "link.yaml")); err != nil {
		t.Skipf("cannot create symlink: %v", err)
	}
	_, err := BuildStage(context.Background(), StageOptions{
		Layout: up, LocalLayer: layer, StageDir: filepath.Join(work, "stage", "s"), TargetDir: t.TempDir(),
	})
	if err == nil {
		t.Fatal("a symlink inside a layer must be rejected")
	}
}

func TestBuildStageRejectsSymlinkedStagePath(t *testing.T) {
	work := t.TempDir()
	up := testUpstream(t, work)
	outside := t.TempDir()
	writeTestFile(t, filepath.Join(outside, "keep.yaml"), "keep\n")
	if err := os.MkdirAll(filepath.Join(work, "stage"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(work, "stage", "s")); err != nil {
		t.Skipf("cannot create symlink: %v", err)
	}
	_, err := BuildStage(context.Background(), StageOptions{
		Layout: up, StageDir: filepath.Join(work, "stage", "s"), WorkDir: work,
		TargetDir: t.TempDir(),
	})
	if err == nil {
		t.Fatal("a stage path through a symlink must be rejected")
	}
	if got := readTestFile(t, filepath.Join(outside, "keep.yaml")); got != "keep\n" {
		t.Fatalf("symlink destination was modified: %q", got)
	}
}

func TestBuildStageRejectsHiddenSubdirectory(t *testing.T) {
	work := t.TempDir()
	up := testUpstream(t, work)
	layer := t.TempDir()
	writeTestFile(t, filepath.Join(layer, ".private", "data.yaml"), "x\n")
	_, err := BuildStage(context.Background(), StageOptions{
		Layout: up, LocalLayer: layer, StageDir: filepath.Join(work, "stage", "hidden"), WorkDir: work,
		TargetDir: t.TempDir(),
	})
	if err == nil {
		t.Fatal("a hidden subdirectory in a layer must be rejected")
	}
}

func TestBuildStageCustomDirIsCaseInsensitiveSeed(t *testing.T) {
	work := t.TempDir()
	up := testUpstream(t, work)
	writeTestFile(t, filepath.Join(up.BaseDir, "Custom", "mine.custom.yaml"), "patch: {}\n")
	s, err := BuildStage(context.Background(), StageOptions{
		Layout: up, StageDir: filepath.Join(work, "stage", "c"), WorkDir: work, TargetDir: t.TempDir(),
	})
	if err != nil {
		t.Fatal(err)
	}
	if c := classOf(t, s, "Custom/mine.custom.yaml"); c != Seed {
		t.Fatalf("Custom/ must be a seed regardless of case, got %v", c)
	}
}

func TestBuildStageRejectsLayerJunkFiles(t *testing.T) {
	work := t.TempDir()
	up := testUpstream(t, work)
	layer := t.TempDir()
	writeTestFile(t, filepath.Join(layer, "wanxiang.custom.yaml"), "patch: {}\n")
	for _, junk := range []string{"notes.md", "backup.yaml.bak", ".DS_Store", "draft.yaml~", "helper.sh", "private.txt.gz"} {
		t.Run(junk, func(t *testing.T) {
			writeTestFile(t, filepath.Join(layer, junk), "x\n")
			t.Cleanup(func() { _ = os.Remove(filepath.Join(layer, junk)) })
			_, err := BuildStage(context.Background(), StageOptions{
				Layout: up, LocalLayer: layer, StageDir: filepath.Join(work, "stage", "junk"), WorkDir: work,
				TargetDir: t.TempDir(),
			})
			if err == nil {
				t.Fatalf("%s in a layer must be rejected", junk)
			}
		})
	}
}

func TestBuildStageMissingLayerFails(t *testing.T) {
	work := t.TempDir()
	up := testUpstream(t, work)
	_, err := BuildStage(context.Background(), StageOptions{
		Layout: up, LocalLayer: filepath.Join(t.TempDir(), "missing"), StageDir: filepath.Join(work, "stage", "s"),
	})
	if err == nil {
		t.Fatal("a configured but missing layer must fail")
	}
}
