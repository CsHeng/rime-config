package update

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// RejectSymlinkedPath refuses a path below root whose existing components are
// symbolic links. The workspace itself may be a link (the user's declared
// location), but nothing below it may redirect writes or deletions elsewhere.
func RejectSymlinkedPath(root, target string) error {
	root = filepath.Clean(root)
	target = filepath.Clean(target)
	rel, err := filepath.Rel(root, target)
	if err != nil {
		return fmt.Errorf("resolve workspace path %s: %w", target, err)
	}
	if rel == "." {
		return nil
	}
	if rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return fmt.Errorf("path %s is outside workspace %s", target, root)
	}
	cur := root
	for _, seg := range strings.Split(rel, string(filepath.Separator)) {
		if seg == "" || seg == "." {
			continue
		}
		cur = filepath.Join(cur, seg)
		st, err := os.Lstat(cur)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			return err
		}
		if st.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("workspace path %s is a symlink; refusing to rebuild or write below it", cur)
		}
	}
	return nil
}
