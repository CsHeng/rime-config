package update

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"
)

// Fetch actions reported for each resource.
const (
	ActionDownloaded = "downloaded"
	ActionReused     = "reused"
	ActionRestored   = "restored"
)

// Status reports what happened to one resource.
type Status struct {
	Resource string
	Version  string
	Action   string
}

// FetchOptions configures Ensure.
type FetchOptions struct {
	WorkDir string
	// Client is required unless NoDownload is set.
	Client *Client
	// NoDownload forbids all network access; only owned cache and already
	// adopted upstream content may be used.
	NoDownload bool
	Log        io.Writer
}

// Ensure makes the three upstream resources available under the work dir,
// reusing verified cache content and never clearing the last usable upstream
// content on failure.
func Ensure(ctx context.Context, o FetchOptions) (Layout, []Status, error) {
	layout := upstreamLayout(o.WorkDir)
	if o.WorkDir == "" {
		return layout, nil, errors.New("missing work directory")
	}
	if !o.NoDownload && o.Client == nil {
		return layout, nil, errors.New("missing HTTP client")
	}
	for _, dir := range []string{
		filepath.Join(o.WorkDir, "cache"),
		filepath.Join(o.WorkDir, "upstream"),
	} {
		if err := RejectSymlinkedPath(o.WorkDir, dir); err != nil {
			return layout, nil, err
		}
	}
	var statuses []Status
	for _, spec := range Specs {
		if err := ctx.Err(); err != nil {
			return layout, statuses, err
		}
		st, err := ensureOne(ctx, o, layout, spec)
		if err != nil {
			return layout, statuses, err
		}
		statuses = append(statuses, st)
	}
	return layout, statuses, nil
}

func ensureOne(ctx context.Context, o FetchOptions, layout Layout, spec Spec) (Status, error) {
	cache := cacheFor(o.WorkDir, spec)
	for _, dir := range []string{cache.dir, filepath.Join(cache.dir, "payload")} {
		if err := RejectSymlinkedPath(o.WorkDir, dir); err != nil {
			return Status{}, err
		}
	}
	if spec.Name == ResourceModel {
		if err := RejectSymlinkedPath(o.WorkDir, layout.ModelDir); err != nil {
			return Status{}, err
		}
	}
	cached, cachedErr := readMarker(cache.marker)

	if o.NoDownload {
		if upstreamReady(layout, spec) {
			return Status{Resource: spec.Name, Version: cached.Version, Action: ActionReused}, nil
		}
		if cachedErr != nil || !payloadIntact(cache, cached) {
			return Status{}, fmt.Errorf("%s: --no-download is set and no local upstream content or cache is available", spec.Name)
		}
		if err := adoptPayload(spec, cache.payload, layout, o.WorkDir); err != nil {
			return Status{}, fmt.Errorf("%s: restore from cache: %w", spec.Name, err)
		}
		return Status{Resource: spec.Name, Version: cached.Version, Action: ActionRestored}, nil
	}

	sel, err := selectRelease(ctx, o.Client, spec)
	if err != nil {
		return Status{}, err
	}
	cacheValid := cachedErr == nil && cached.Version == sel.Version && payloadIntact(cache, cached)
	if cacheValid && upstreamReady(layout, spec) {
		return Status{Resource: spec.Name, Version: sel.Version, Action: ActionReused}, nil
	}
	if cacheValid {
		if err := adoptPayload(spec, cache.payload, layout, o.WorkDir); err != nil {
			return Status{}, fmt.Errorf("%s: restore from cache: %w", spec.Name, err)
		}
		return Status{Resource: spec.Name, Version: sel.Version, Action: ActionRestored}, nil
	}

	logf(o.Log, "resource %s: downloading %s (%s)", spec.Name, sel.Tag, sel.URL)
	tmp, size, sha, err := o.Client.download(ctx, sel.URL, cache.dir)
	if err != nil {
		return Status{}, fmt.Errorf("%s: %w", spec.Name, err)
	}
	defer os.Remove(tmp)

	if err := adoptPayload(spec, tmp, layout, o.WorkDir); err != nil {
		return Status{}, fmt.Errorf("%s: adopt new content: %w", spec.Name, err)
	}
	if err := os.MkdirAll(filepath.Dir(cache.payload), 0o755); err != nil {
		return Status{}, err
	}
	if err := os.Rename(tmp, cache.payload); err != nil {
		return Status{}, fmt.Errorf("%s: save cache: %w", spec.Name, err)
	}
	m := marker{
		Resource:  spec.Name,
		Version:   sel.Version,
		Tag:       sel.Tag,
		AssetName: sel.AssetName,
		URL:       redactURL(sel.URL),
		SHA256:    sha,
		Size:      size,
		FetchedAt: time.Now().UTC(),
	}
	if err := writeMarker(cache.marker, m); err != nil {
		return Status{}, fmt.Errorf("%s: write cache marker: %w", spec.Name, err)
	}
	return Status{Resource: spec.Name, Version: sel.Version, Action: ActionDownloaded}, nil
}

// payloadIntact verifies that the cached payload still matches its marker.
func payloadIntact(cache cachePaths, m marker) bool {
	st, err := os.Stat(cache.payload)
	if err != nil || !st.Mode().IsRegular() || st.Size() != m.Size {
		return false
	}
	sha, err := fileSHA256(cache.payload)
	if err != nil {
		return false
	}
	return sha == m.SHA256
}

// adoptPayload installs payload content into the adopted upstream layout. The
// previous content stays in place when adoption fails.
func adoptPayload(spec Spec, payload string, layout Layout, workDir string) error {
	switch spec.Name {
	case ResourceBase, ResourceDicts:
		tmp, err := os.MkdirTemp(workDir, ".extract-*")
		if err != nil {
			return err
		}
		defer os.RemoveAll(tmp)
		if err := extractZip(payload, tmp, spec.Name == ResourceDicts); err != nil {
			return err
		}
		if !dirHasFiles(tmp) {
			return errors.New("archive extracted no files; refusing to replace upstream with empty content")
		}
		dst := layout.BaseDir
		if spec.Name == ResourceDicts {
			dst = layout.DictsDir
		}
		return replaceDir(tmp, dst)
	case ResourceModel:
		if err := os.MkdirAll(layout.ModelDir, 0o755); err != nil {
			return err
		}
		return copyFile(payload, layout.ModelFile)
	default:
		return fmt.Errorf("unknown upstream resource %q", spec.Name)
	}
}

func logf(w io.Writer, format string, args ...any) {
	if w == nil {
		return
	}
	fmt.Fprintf(w, format+"\n", args...)
}
