package update

import (
	"archive/zip"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"

	"rime-config-go/internal/config"
)

// extractZip extracts an upstream archive into dest, rejecting entries that
// would escape dest, symlinks and non-regular entries. When flatten is set all
// files land directly in dest and duplicate names are rejected.
func extractZip(zipPath, dest string, flatten bool) error {
	r, err := zip.OpenReader(zipPath)
	if err != nil {
		return fmt.Errorf("open ZIP %s: %w", zipPath, err)
	}
	defer r.Close()

	strip := singleTopDirectory(r.File)
	seen := map[string]string{}

	for _, f := range r.File {
		raw := strings.ReplaceAll(f.Name, `\`, "/")
		name, err := config.CleanRelative(raw)
		if err != nil {
			return fmt.Errorf("ZIP entry %q: %w", f.Name, err)
		}
		if strip != "" {
			if name == strip {
				continue
			}
			if !strings.HasPrefix(name, strip+"/") {
				return fmt.Errorf("ZIP entry %q is outside the single top-level directory %q", f.Name, strip)
			}
			name = strings.TrimPrefix(name, strip+"/")
		}
		if name == "" {
			continue
		}
		mode := f.Mode()
		if mode&os.ModeSymlink != 0 {
			return fmt.Errorf("ZIP entry %q is a symlink; refusing to extract", f.Name)
		}
		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(filepath.Join(dest, filepath.FromSlash(name)), 0o755); err != nil {
				return err
			}
			continue
		}
		if mode != 0 && !mode.IsRegular() {
			return fmt.Errorf("ZIP entry %q is not a regular file", f.Name)
		}
		if f.UncompressedSize64 > 1<<31 {
			return fmt.Errorf("ZIP entry %q is too large (%d bytes)", f.Name, f.UncompressedSize64)
		}
		rel := name
		if flatten {
			rel = path.Base(name)
			if prev, ok := seen[rel]; ok {
				return fmt.Errorf("dictionary flattening collision: %q and %q both map to %q", prev, name, rel)
			}
			seen[rel] = name
		}
		outPath := filepath.Join(dest, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(outPath), 0o755); err != nil {
			return err
		}
		if err := writeZipEntry(f, outPath); err != nil {
			return fmt.Errorf("extract %q: %w", f.Name, err)
		}
	}
	return nil
}

// singleTopDirectory returns the only top level directory of the archive when
// every entry lives below it, so archives that wrap their content in one
// folder are adopted as if the wrapper did not exist. Malformed entries make it
// return "", leaving the rejection to extractZip.
func singleTopDirectory(files []*zip.File) string {
	top := ""
	for _, f := range files {
		name, err := config.CleanRelative(strings.ReplaceAll(f.Name, `\`, "/"))
		if err != nil || name == "" {
			return ""
		}
		if !strings.Contains(name, "/") {
			if strings.HasSuffix(strings.ReplaceAll(f.Name, `\`, "/"), "/") {
				// A top level directory is a wrapper candidate only when it is
				// the single top level entry of the archive.
				if top == "" {
					top = name
				} else if top != name {
					return ""
				}
				continue
			}
			// A top level file means there is no wrapping directory.
			return ""
		}
		first := name[:strings.Index(name, "/")]
		if top == "" {
			top = first
		} else if top != first {
			return ""
		}
	}
	return top
}

func writeZipEntry(f *zip.File, outPath string) error {
	in, err := f.Open()
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(outPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}
