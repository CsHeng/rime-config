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

	"rime-config/internal/config"
)

// Protect describes which target paths must never be written or deleted.
type Protect struct {
	// Exclude patterns are user declared keeps: skipped for copy and delete.
	Exclude []string
	// NeverWrite adds configuration specific paths that must not be written.
	NeverWrite []string
	// NeverDelete adds configuration specific paths that may be written but
	// not deleted.
	NeverDelete []string
	// PhraseFile is the user owned phrase dictionary at the target root. It is
	// empty when a repository layer manages the phrase file.
	PhraseFile string
}

// SyncOptions configures distribution of one stage into one target.
type SyncOptions struct {
	Stage     *Stage
	TargetDir string
	Protect   Protect
	Delete    bool
	DryRun    bool
	// Out receives the human readable plan. In dry-run mode the plan is the
	// only output and nothing is changed.
	Out io.Writer
}

// SyncResult summarizes one distribution run.
type SyncResult struct {
	// Copied lists every written file; Updated is the subset that replaced an
	// existing, different target file.
	Copied     []string
	Updated    []string
	Skipped    []string
	Kept       []string
	Deleted    []string
	MkDirs     []string
	PrunedDirs []string
}

// SyncTarget copies the stage into the target, honoring protection rules and
// optionally deleting target entries that no longer exist in the stage.
//
// Seed files (upstream custom/** and the user phrase template) are only
// created when missing. They never need an ownership record: custom/ and the
// user phrase file are protected from deletion by path.
func SyncTarget(ctx context.Context, o SyncOptions) (*SyncResult, error) {
	res := &SyncResult{}
	if o.Stage == nil {
		return res, errors.New("missing stage")
	}
	target := filepath.Clean(o.TargetDir)
	stageDir := filepath.Clean(o.Stage.Dir)
	if target == "" || target == "." {
		return res, errors.New("missing target directory")
	}
	if samePath(target, stageDir) {
		return res, fmt.Errorf("target directory equals the stage directory: %s", target)
	}
	if isSubpath(target, stageDir) || isSubpath(stageDir, target) {
		return res, fmt.Errorf("stage directory %s overlaps target directory %s", stageDir, target)
	}
	if err := PreflightTarget(target); err != nil {
		return res, err
	}
	if !o.DryRun {
		if _, err := os.Stat(target); errors.Is(err, os.ErrNotExist) {
			if err := os.MkdirAll(target, 0o755); err != nil {
				return res, fmt.Errorf("create target directory %s: %w", target, err)
			}
			res.MkDirs = append(res.MkDirs, target)
		}
	} else if _, err := os.Stat(target); errors.Is(err, os.ErrNotExist) {
		planf(o, "mkdir  %s", target)
	}

	stage := map[string]File{}
	stageFolded := map[string]bool{}
	for _, f := range o.Stage.Files {
		if _, err := config.CleanRelative(f.Rel); err != nil {
			return res, err
		}
		key := strings.ToLower(f.Rel)
		if stageFolded[key] {
			return res, fmt.Errorf("stage contains paths that differ only in case: %q", f.Rel)
		}
		stageFolded[key] = true
		stage[f.Rel] = f
	}

	rels := make([]string, 0, len(stage))
	for rel := range stage {
		rels = append(rels, rel)
	}
	sort.Strings(rels)

	for _, rel := range rels {
		if err := ctx.Err(); err != nil {
			return res, err
		}
		file := stage[rel]
		if reason := o.Protect.coreProtection(rel); reason != "" {
			res.Kept = append(res.Kept, rel)
			planf(o, "keep   %s (%s)", rel, reason)
			continue
		}
		if matchAnyTree(o.Protect.Exclude, rel) {
			res.Kept = append(res.Kept, rel)
			planf(o, "keep   %s (excluded)", rel)
			continue
		}
		if file.Class == Seed {
			if fileExists(filepath.Join(target, filepath.FromSlash(rel))) {
				res.Kept = append(res.Kept, rel)
				planf(o, "keep   %s (seed exists, not overwritten)", rel)
				continue
			}
		} else if reason := o.Protect.managedProtection(rel); reason != "" {
			res.Kept = append(res.Kept, rel)
			planf(o, "keep   %s (%s)", rel, reason)
			continue
		}
		src := filepath.Join(stageDir, filepath.FromSlash(rel))
		dst := filepath.Join(target, filepath.FromSlash(rel))
		identical, err := filesEqual(src, dst)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return res, fmt.Errorf("compare target file %s: %w", rel, err)
		}
		if identical {
			res.Skipped = append(res.Skipped, rel)
			planf(o, "same   %s", rel)
			continue
		}
		res.Copied = append(res.Copied, rel)
		exists := fileExists(dst)
		if exists {
			res.Updated = append(res.Updated, rel)
		}
		if o.DryRun {
			if exists {
				planf(o, "update %s", rel)
			} else {
				planf(o, "copy   %s", rel)
			}
			continue
		}
		created, err := ensureDirs(target, path.Dir(rel))
		if err != nil {
			return res, fmt.Errorf("create directory %s: %w", path.Dir(rel), err)
		}
		res.MkDirs = append(res.MkDirs, created...)
		if err := copyFile(src, dst); err != nil {
			return res, fmt.Errorf("copy %s: %w", rel, err)
		}
	}

	if o.Delete {
		deleted, pruned, err := deleteMissing(ctx, target, stageFolded, o.Protect, o.DryRun, o.Out)
		res.Deleted = append(res.Deleted, deleted...)
		res.PrunedDirs = append(res.PrunedDirs, pruned...)
		if err != nil {
			return res, err
		}
	}

	return res, nil
}

// PreflightTarget performs the read-only checks for one write target: it must
// be a directory if it exists, must not be a symlink, and must not contain
// symlinks that escape it. It is safe to call before any side effect.
func PreflightTarget(target string) error {
	st, err := os.Lstat(target)
	switch {
	case err == nil && st.Mode()&os.ModeSymlink != 0:
		return fmt.Errorf("target directory %s is a symlink; refusing to write", target)
	case err == nil && !st.IsDir():
		return fmt.Errorf("target %s is not a directory", target)
	case err != nil && !errors.Is(err, os.ErrNotExist):
		return err
	case errors.Is(err, os.ErrNotExist):
		return nil
	}
	return checkSymlinkEscape(target)
}

func planf(o SyncOptions, format string, args ...any) {
	if o.DryRun && o.Out != nil {
		fmt.Fprintf(o.Out, format+"\n", args...)
	}
}

// coreProtection covers device state that must never be written at all.
func (p Protect) coreProtection(rel string) string {
	if coreNeverWrite(rel) {
		return "protected user state"
	}
	return ""
}

// managedProtection covers configuration specific paths that the tool must not
// overwrite. Seed files are handled separately because a missing seed file is
// created once.
func (p Protect) managedProtection(rel string) string {
	if p.PhraseFile != "" && strings.EqualFold(rel, p.PhraseFile) {
		return "user phrase file"
	}
	if matchAnyTree(p.NeverWrite, rel) {
		return "protected by config"
	}
	return ""
}

func (p Protect) neverDelete(rel string) bool {
	if p.coreProtection(rel) != "" || p.managedProtection(rel) != "" {
		return true
	}
	if matchAnyTree(p.Exclude, rel) || matchAnyTree(p.NeverDelete, rel) {
		return true
	}
	return coreNeverDelete(rel)
}

// coreNeverWrite protects device state and compiled data inside a target.
// Comparisons are case-insensitive because Windows and default macOS
// filesystems treat such names as the same file.
func coreNeverWrite(rel string) bool {
	segs := strings.Split(rel, "/")
	for i, s := range segs {
		switch {
		case strings.EqualFold(s, "user.yaml"), strings.EqualFold(s, "installation.yaml"):
			return true
		case hasSuffixFold(s, ".userdb"), hasSuffixFold(s, ".userdb.txt"):
			return true
		case i == 0 && strings.EqualFold(s, "build"):
			return true
		}
	}
	return false
}

func hasSuffixFold(s, suffix string) bool {
	if len(s) < len(suffix) {
		return false
	}
	return strings.EqualFold(s[len(s)-len(suffix):], suffix)
}

// matchAnyTree also checks every ancestor directory of rel, so excluding a
// directory protects all of its descendants for both copy and delete.
func matchAnyTree(patterns []string, rel string) bool {
	if matchAny(patterns, rel) {
		return true
	}
	segs := strings.Split(rel, "/")
	for i := 1; i < len(segs); i++ {
		if matchAny(patterns, strings.Join(segs[:i], "/")) {
			return true
		}
	}
	return false
}

// coreNeverDelete protects user maintained trees from --delete while still
// allowing the tool to distribute updated content into them. The custom/
// reference directory belongs to the user and is only seeded once.
func coreNeverDelete(rel string) bool {
	first := rel
	if i := strings.Index(first, "/"); i >= 0 {
		first = first[:i]
	}
	return strings.EqualFold(first, "lua") || strings.EqualFold(first, "tips") || strings.EqualFold(first, "custom")
}

// matchAny reports whether rel matches one of the simple patterns. A pattern
// containing "/" is matched against the whole relative path; otherwise it is
// matched against the base name. A trailing "/" or any pattern also matches the
// whole subtree below it.
func matchAny(patterns []string, rel string) bool {
	for _, pat := range patterns {
		if matchPattern(pat, rel) {
			return true
		}
	}
	return false
}

func matchPattern(pattern, rel string) bool {
	pat := strings.TrimSpace(strings.ReplaceAll(pattern, `\`, "/"))
	if pat == "" {
		return false
	}
	dirOnly := strings.HasSuffix(pat, "/")
	pat = strings.TrimSuffix(pat, "/")
	if pat == "" {
		return false
	}
	if !dirOnly {
		if strings.Contains(pat, "/") {
			if ok, _ := path.Match(pat, rel); ok {
				return true
			}
		} else if ok, _ := path.Match(pat, path.Base(rel)); ok {
			return true
		}
	}
	return rel == pat || strings.HasPrefix(rel, pat+"/")
}

func ensureDirs(root, dirRel string) ([]string, error) {
	var created []string
	if dirRel == "." || dirRel == "" {
		return created, nil
	}
	cur := root
	for _, seg := range strings.Split(filepath.ToSlash(dirRel), "/") {
		if seg == "" || seg == "." {
			continue
		}
		cur = filepath.Join(cur, seg)
		st, err := os.Lstat(cur)
		switch {
		case err == nil && st.Mode()&os.ModeSymlink != 0:
			return created, fmt.Errorf("path %s is a symlink; refusing to write", cur)
		case err == nil && !st.IsDir():
			return created, fmt.Errorf("path %s exists and is not a directory", cur)
		case err == nil:
			continue
		case errors.Is(err, os.ErrNotExist):
			if err := os.Mkdir(cur, 0o755); err != nil {
				return created, err
			}
			created = append(created, cur)
		default:
			return created, err
		}
	}
	return created, nil
}

// deleteMissing removes target entries that are absent from the stage unless
// they are protected, and prunes directories that became empty. Cancellation
// is checked before every removal.
func deleteMissing(ctx context.Context, target string, stageFolded map[string]bool, protect Protect, dryRun bool, out io.Writer) ([]string, []string, error) {
	var candidates []string
	var dirs []string
	protectedDirs := map[string]bool{}

	err := filepath.WalkDir(target, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		relOS, err := filepath.Rel(target, p)
		if err != nil {
			return err
		}
		rel := filepath.ToSlash(relOS)
		if rel == "." {
			return nil
		}
		if d.IsDir() {
			if protect.neverDelete(rel) {
				protectedDirs[rel] = true
				return fs.SkipDir
			}
			dirs = append(dirs, rel)
			return nil
		}
		if stageFolded[strings.ToLower(rel)] || protect.neverDelete(rel) {
			return nil
		}
		candidates = append(candidates, rel)
		return nil
	})
	if err != nil {
		return nil, nil, fmt.Errorf("scan target directory: %w", err)
	}

	var deleted []string
	for _, rel := range candidates {
		if err := ctx.Err(); err != nil {
			return deleted, nil, err
		}
		if dryRun {
			if out != nil {
				fmt.Fprintf(out, "delete %s\n", rel)
			}
			deleted = append(deleted, rel)
			continue
		}
		if err := os.Remove(filepath.Join(target, filepath.FromSlash(rel))); err != nil && !errors.Is(err, os.ErrNotExist) {
			return deleted, nil, fmt.Errorf("delete %s: %w", rel, err)
		}
		deleted = append(deleted, rel)
	}

	var pruned []string
	sort.Slice(dirs, func(i, j int) bool {
		return len(dirs[i]) > len(dirs[j])
	})
	for _, rel := range dirs {
		if err := ctx.Err(); err != nil {
			return deleted, pruned, err
		}
		if protectedDirs[rel] {
			continue
		}
		full := filepath.Join(target, filepath.FromSlash(rel))
		entries, err := os.ReadDir(full)
		if err != nil || len(entries) > 0 {
			continue
		}
		if dryRun {
			if out != nil {
				fmt.Fprintf(out, "rmdir  %s\n", rel)
			}
			pruned = append(pruned, rel)
			continue
		}
		if err := os.Remove(full); err != nil {
			continue
		}
		pruned = append(pruned, rel)
	}
	return deleted, pruned, nil
}

// checkSymlinkEscape refuses targets containing symlinks that resolve outside
// the target tree.
func checkSymlinkEscape(target string) error {
	root, err := filepath.EvalSymlinks(target)
	if err != nil {
		return err
	}
	var offending error
	err = filepath.WalkDir(target, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.Type()&os.ModeSymlink == 0 {
			return nil
		}
		resolved, err := filepath.EvalSymlinks(p)
		if err != nil {
			offending = fmt.Errorf("symlink %s cannot be resolved: %w", p, err)
			return filepath.SkipAll
		}
		if resolved != root && !isSubpath(resolved, root) {
			offending = fmt.Errorf("symlink %s points outside the target directory (%s); refusing to write", p, resolved)
			return filepath.SkipAll
		}
		return nil
	})
	if err != nil {
		return err
	}
	return offending
}

func samePath(a, b string) bool {
	if filepath.Clean(a) == filepath.Clean(b) {
		return true
	}
	ra, errA := filepath.EvalSymlinks(a)
	rb, errB := filepath.EvalSymlinks(b)
	return errA == nil && errB == nil && ra == rb
}

func isSubpath(child, parent string) bool {
	rc, err := filepath.Rel(parent, child)
	if err != nil {
		return false
	}
	return rc != "." && rc != ".." && !strings.HasPrefix(rc, ".."+string(filepath.Separator))
}

func fileExists(p string) bool {
	st, err := os.Lstat(p)
	return err == nil && st.Mode().IsRegular()
}
