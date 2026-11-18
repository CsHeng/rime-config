package update

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
)

// Class is the ownership class of a staged file.
type Class int

const (
	// Managed files are overwritten with the staged content and are candidates
	// for deletion when --delete is requested.
	Managed Class = iota
	// Seed files are only created when missing; they are never overwritten and
	// never deleted.
	Seed
)

// File is one staged file with its ownership class.
type File struct {
	Rel   string
	Class Class
}

// Stage is a fully materialized per-frontend file tree.
type Stage struct {
	Dir   string
	Files []File
	// PhraseManaged reports that a repository layer provides the user phrase
	// file, which then overwrites the target copy like any managed file.
	PhraseManaged bool
}

// StageOptions describes how to compose one frontend stage.
type StageOptions struct {
	Layout      Layout
	LocalLayer  string
	CommonLayer string
	UILayer     string
	StageDir    string
	// WorkDir is the declared tool workspace. When set, the stage path may not
	// traverse a symlink below it, so a rebuild can never reach outside the
	// workspace.
	WorkDir string
	// TargetDir is only read, to decide whether an unmanaged user phrase file
	// already exists and therefore must not be seeded or overwritten.
	TargetDir      string
	UserPhraseFile string
	PhraseExample  string
}

// BuildStage composes upstream, local, shared and frontend layers into the
// rebuildable stage directory. Later layers overwrite earlier ones in the
// documented order: upstream, local, common UI, frontend UI.
//
// The user phrase file is managed when a repository layer provides it (the
// repository copy is the master). Otherwise an existing target copy is left
// alone, and a missing one is seeded once from the template.
func BuildStage(ctx context.Context, o StageOptions) (*Stage, error) {
	if strings.TrimSpace(o.StageDir) == "" {
		return nil, errors.New("missing stage directory")
	}
	if o.WorkDir != "" {
		if err := RejectSymlinkedPath(o.WorkDir, o.StageDir); err != nil {
			return nil, err
		}
	}
	if err := os.RemoveAll(o.StageDir); err != nil {
		return nil, fmt.Errorf("clean stage directory %s: %w", o.StageDir, err)
	}
	if err := os.MkdirAll(o.StageDir, 0o755); err != nil {
		return nil, err
	}
	classes := map[string]Class{}
	add := func(rel string, class Class) {
		if isUserOwnedPath(rel) {
			class = Seed
		}
		classes[rel] = class
	}

	if err := overlayTree(ctx, o.Layout.BaseDir, "", o.StageDir, add, false); err != nil {
		return nil, fmt.Errorf("stage upstream base: %w", err)
	}
	if err := overlayTree(ctx, o.Layout.DictsDir, "dicts", o.StageDir, add, false); err != nil {
		return nil, fmt.Errorf("stage upstream dictionaries: %w", err)
	}
	if o.Layout.ModelFile != "" {
		rel := filepath.Base(o.Layout.ModelFile)
		if err := copyFile(o.Layout.ModelFile, filepath.Join(o.StageDir, rel)); err != nil {
			return nil, fmt.Errorf("stage upstream grammar model: %w", err)
		}
		add(rel, Managed)
	}
	phraseManaged := false
	layers := []struct {
		dir  string
		name string
	}{
		{o.LocalLayer, "local layer"},
		{o.CommonLayer, "common UI layer"},
		{o.UILayer, "frontend UI layer"},
	}
	for _, layer := range layers {
		if err := overlayTree(ctx, layer.dir, "", o.StageDir, func(rel string, c Class) {
			if o.UserPhraseFile != "" && strings.EqualFold(rel, o.UserPhraseFile) {
				phraseManaged = true
			}
			add(rel, Managed)
		}, true); err != nil {
			return nil, fmt.Errorf("stage %s: %w", layer.name, err)
		}
	}

	if name := o.UserPhraseFile; name != "" && !phraseManaged {
		target := filepath.Join(o.StageDir, filepath.FromSlash(name))
		if userPhraseExists(o.TargetDir, name) {
			// Without a repository master the target copy belongs to the
			// user; neither stage nor distribution may replace it.
			if err := os.Remove(target); err != nil && !errors.Is(err, os.ErrNotExist) {
				return nil, fmt.Errorf("drop staged user phrase file: %w", err)
			}
			delete(classes, name)
		} else if o.PhraseExample != "" {
			if err := copyFile(o.PhraseExample, target); err != nil {
				return nil, fmt.Errorf("stage user phrase template: %w", err)
			}
			add(name, Seed)
		}
	}

	files := make([]File, 0, len(classes))
	for rel, class := range classes {
		files = append(files, File{Rel: rel, Class: class})
	}
	sort.Slice(files, func(i, j int) bool { return files[i].Rel < files[j].Rel })
	return &Stage{Dir: o.StageDir, Files: files, PhraseManaged: phraseManaged}, nil
}

// isUserOwnedPath reports whether a relative target path belongs to the user by
// convention: the custom/ reference directory is only seeded once.
func isUserOwnedPath(rel string) bool {
	first := rel
	if i := strings.Index(first, "/"); i >= 0 {
		first = first[:i]
	}
	return strings.EqualFold(first, "custom")
}

func userPhraseExists(targetDir, name string) bool {
	if targetDir == "" {
		return false
	}
	st, err := os.Stat(filepath.Join(targetDir, filepath.FromSlash(name)))
	return err == nil && st.Mode().IsRegular()
}

// overlayTree copies every regular file below src into stage under prefix. In
// strict mode (repository owned layers) auxiliary files that are not payload
// are rejected instead of being distributed by accident.
func overlayTree(ctx context.Context, src, prefix, stageDir string, add func(rel string, class Class), strict bool) error {
	if strings.TrimSpace(src) == "" {
		return nil
	}
	st, err := os.Stat(src)
	if err != nil {
		return fmt.Errorf("directory %s: %w", src, err)
	}
	if !st.IsDir() {
		return fmt.Errorf("%s is not a directory", src)
	}
	return filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		if d.Type()&os.ModeSymlink != 0 {
			return fmt.Errorf("%s is a symlink; refusing to stage it", p)
		}
		if !d.Type().IsRegular() {
			return fmt.Errorf("%s is not a regular file; refusing to stage it", p)
		}
		rel, err := filepath.Rel(src, p)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		if prefix != "" {
			rel = prefix + "/" + rel
		}
		if strict {
			if err := checkLayerPayload(rel); err != nil {
				return err
			}
		}
		dst := filepath.Join(stageDir, filepath.FromSlash(rel))
		if err := copyFile(p, dst); err != nil {
			return fmt.Errorf("stage file %s: %w", rel, err)
		}
		add(rel, Managed)
		return nil
	})
}

// PreflightLayer performs the same read-only validation that BuildStage applies
// to repository owned layers: it must be a directory, contain only regular
// payload files and no symlinks or hidden path segments.
func PreflightLayer(dir string) error {
	if strings.TrimSpace(dir) == "" {
		return nil
	}
	st, err := os.Stat(dir)
	if err != nil {
		return err
	}
	if !st.IsDir() {
		return fmt.Errorf("%s is not a directory", dir)
	}
	return filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.Type()&os.ModeSymlink != 0 {
			return fmt.Errorf("%s is a symlink; refusing to stage it", p)
		}
		if d.IsDir() {
			return nil
		}
		if !d.Type().IsRegular() {
			return fmt.Errorf("%s is not a regular file; refusing to stage it", p)
		}
		rel, err := filepath.Rel(dir, p)
		if err != nil {
			return err
		}
		return checkLayerPayload(filepath.ToSlash(rel))
	})
}

// checkLayerPayload rejects obvious non-payload files in repository owned
// layers. Upstream archives are adopted as published and are not filtered here.
func checkLayerPayload(rel string) error {
	for _, seg := range strings.Split(rel, "/") {
		if strings.HasPrefix(seg, ".") {
			return fmt.Errorf("layer contains hidden path %q; move it out of the layer", rel)
		}
	}
	base := strings.ToLower(path.Base(rel))
	// Positive payload rule: repository layers may only add files that Rime or
	// the documented Hamster include list consume. Anything else must be
	// declared explicitly by extending this list.
	for _, suffix := range []string{".yaml", ".yml", ".txt", ".json"} {
		if strings.HasSuffix(base, suffix) {
			return nil
		}
	}
	return fmt.Errorf("layers may only contain .yaml/.yml/.txt/.json payload, found %q; move it out of the layer", rel)
}

// copyFile copies src to dst through a temporary file in dst's directory.
func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	st, err := in.Stat()
	if err != nil {
		return err
	}
	if !st.Mode().IsRegular() {
		return fmt.Errorf("%s is not a regular file", src)
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(dst), ".copy-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	if _, err := io.Copy(tmp, in); err != nil {
		tmp.Close()
		os.Remove(name)
		return err
	}
	if err := tmp.Chmod(0o644); err != nil {
		tmp.Close()
		os.Remove(name)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(name)
		return err
	}
	if err := os.Rename(name, dst); err != nil {
		os.Remove(name)
		return err
	}
	return nil
}

// filesEqual reports whether two regular files have identical content.
func filesEqual(a, b string) (bool, error) {
	sa, err := os.Stat(a)
	if err != nil {
		return false, err
	}
	sb, err := os.Stat(b)
	if err != nil {
		return false, err
	}
	if !sb.Mode().IsRegular() || sa.Size() != sb.Size() {
		return false, nil
	}
	fa, err := os.Open(a)
	if err != nil {
		return false, err
	}
	defer fa.Close()
	fb, err := os.Open(b)
	if err != nil {
		return false, err
	}
	defer fb.Close()
	bufA := make([]byte, 64*1024)
	bufB := make([]byte, 64*1024)
	for {
		na, errA := io.ReadFull(fa, bufA)
		nb, errB := io.ReadFull(fb, bufB)
		if na != nb || !equalBytes(bufA[:na], bufB[:nb]) {
			return false, nil
		}
		if errA == io.EOF || errA == io.ErrUnexpectedEOF {
			if errB == io.EOF || errB == io.ErrUnexpectedEOF {
				return true, nil
			}
			return false, nil
		}
		if errA != nil {
			return false, errA
		}
		if errB != nil {
			return false, errB
		}
	}
}

func equalBytes(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
