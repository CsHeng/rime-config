// Package update implements upstream resource retrieval, the rebuildable cache
// and stage, layered file composition and safe distribution to Rime targets.
package update

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Resource names used in cache directories, markers and status output.
const (
	ResourceBase  = "base"
	ResourceDicts = "dicts"
	ResourceModel = "model"
)

// ModelAssetName is the grammar model file name published upstream.
const ModelAssetName = "wanxiang-lts-zh-hans.gram"

// Spec describes one upstream resource.
type Spec struct {
	Name        string
	Repo        string
	TagPrefix   string
	AssetName   string
	VersionFrom string // "tag" or "asset"
}

// Specs are the three upstream resources described by the design. They are
// fixed on purpose: this tool is not a general resource manager.
var Specs = []Spec{
	{
		Name:        ResourceBase,
		Repo:        "amzxyz/rime-wanxiang",
		TagPrefix:   "v",
		AssetName:   "rime-wanxiang-base.zip",
		VersionFrom: "tag",
	},
	{
		Name:        ResourceDicts,
		Repo:        "amzxyz/rime-wanxiang",
		TagPrefix:   "dict-nightly",
		AssetName:   "base-dicts.zip",
		VersionFrom: "asset",
	},
	{
		Name:        ResourceModel,
		Repo:        "amzxyz/rime-wanxiang-data",
		TagPrefix:   "LTS",
		AssetName:   ModelAssetName,
		VersionFrom: "asset",
	},
}

type release struct {
	TagName   string    `json:"tag_name"`
	Draft     bool      `json:"draft"`
	CreatedAt time.Time `json:"created_at"`
	Assets    []asset   `json:"assets"`
}

type asset struct {
	Name               string    `json:"name"`
	Size               int64     `json:"size"`
	UpdatedAt          time.Time `json:"updated_at"`
	BrowserDownloadURL string    `json:"browser_download_url"`
}

// Client talks to the GitHub API. BaseURL is injectable so tests can point it
// at a local server; production always uses the upstream API.
type Client struct {
	BaseURL   string
	HTTP      *http.Client
	Token     string
	UserAgent string
}

// NewClient builds a client for the given API base URL.
func NewClient(baseURL, token string) *Client {
	return &Client{
		BaseURL: strings.TrimRight(baseURL, "/"),
		HTTP: &http.Client{
			Transport: &http.Transport{
				Proxy:                 http.ProxyFromEnvironment,
				ResponseHeaderTimeout: 30 * time.Second,
				IdleConnTimeout:       30 * time.Second,
			},
		},
		Token:     token,
		UserAgent: "rime-config",
	}
}

// The token is only sent to the API host, never to asset download hosts.
func (c *Client) authorized(u *url.URL) bool {
	if c.Token == "" {
		return false
	}
	base, err := url.Parse(c.BaseURL)
	if err != nil {
		return false
	}
	return strings.EqualFold(base.Host, u.Host)
}

func (c *Client) newRequest(ctx context.Context, rawURL string) (*http.Request, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", c.UserAgent)
	if u, err := url.Parse(rawURL); err == nil && c.authorized(u) {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}
	return req, nil
}

func (c *Client) getJSON(ctx context.Context, p string, out any) error {
	req, err := c.newRequest(ctx, c.BaseURL+p)
	if err != nil {
		return err
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("request %s: %w", c.BaseURL+p, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		snippet, _ := io.ReadAll(io.LimitReader(resp.Body, 256))
		return fmt.Errorf("request %s returned HTTP %d: %s", c.BaseURL+p, resp.StatusCode, strings.TrimSpace(string(snippet)))
	}
	body := io.LimitReader(resp.Body, 8<<20)
	dec := json.NewDecoder(body)
	if err := dec.Decode(out); err != nil {
		return fmt.Errorf("parse response of %s: %w", c.BaseURL+p, err)
	}
	return nil
}

// download streams rawURL into a new file inside dir and returns the file
// path, its size and its SHA-256.
func (c *Client) download(ctx context.Context, rawURL, dir string) (string, int64, string, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", 0, "", err
	}
	tmp, err := os.CreateTemp(dir, ".download-*")
	if err != nil {
		return "", 0, "", err
	}
	tmpName := tmp.Name()
	cleanup := func() {
		tmp.Close()
		os.Remove(tmpName)
	}
	req, err := c.newRequest(ctx, rawURL)
	if err != nil {
		cleanup()
		return "", 0, "", err
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		cleanup()
		return "", 0, "", fmt.Errorf("download %s: %w", redactURL(rawURL), err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		snippet, _ := io.ReadAll(io.LimitReader(resp.Body, 256))
		cleanup()
		return "", 0, "", fmt.Errorf("download %s returned HTTP %d: %s", redactURL(rawURL), resp.StatusCode, strings.TrimSpace(string(snippet)))
	}
	hasher := newSHA256()
	size, err := io.Copy(io.MultiWriter(tmp, hasher), resp.Body)
	if err != nil {
		cleanup()
		return "", 0, "", fmt.Errorf("download %s interrupted: %w", redactURL(rawURL), err)
	}
	if err := tmp.Sync(); err != nil {
		cleanup()
		return "", 0, "", err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return "", 0, "", err
	}
	if size == 0 {
		os.Remove(tmpName)
		return "", 0, "", fmt.Errorf("download %s returned an empty file", redactURL(rawURL))
	}
	return tmpName, size, hasher.sum(), nil
}

// redactURL strips query strings so logs never carry tokens in query form.
func redactURL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return raw
	}
	u.RawQuery = ""
	u.Fragment = ""
	return u.String()
}

type selected struct {
	Version   string
	Tag       string
	URL       string
	AssetName string
}

func selectRelease(ctx context.Context, c *Client, spec Spec) (selected, error) {
	var rels []release
	if err := c.getJSON(ctx, "/repos/"+spec.Repo+"/releases?per_page=100", &rels); err != nil {
		return selected{}, fmt.Errorf("%s: list releases of %s: %w", spec.Name, spec.Repo, err)
	}
	var matches []release
	for _, r := range rels {
		if r.Draft || !strings.HasPrefix(r.TagName, spec.TagPrefix) {
			continue
		}
		matches = append(matches, r)
	}
	if len(matches) == 0 {
		return selected{}, fmt.Errorf("%s: %s has no release with tag prefix %q", spec.Name, spec.Repo, spec.TagPrefix)
	}
	best := matches[0]
	for _, r := range matches[1:] {
		if releaseBetter(r, best, spec.TagPrefix) {
			best = r
		}
	}
	a := findAsset(best, spec.AssetName)
	if a == nil {
		names := make([]string, 0, len(best.Assets))
		for _, x := range best.Assets {
			names = append(names, x.Name)
		}
		return selected{}, fmt.Errorf("%s: release %s has no asset %q (available: %s)", spec.Name, best.TagName, spec.AssetName, strings.Join(names, ", "))
	}
	if strings.TrimSpace(a.BrowserDownloadURL) == "" {
		return selected{}, fmt.Errorf("%s: asset %q of release %s has no download URL", spec.Name, spec.AssetName, best.TagName)
	}
	version := best.TagName
	if spec.VersionFrom == "asset" {
		version = a.UpdatedAt.UTC().Format(time.RFC3339)
	}
	return selected{Version: version, Tag: best.TagName, URL: a.BrowserDownloadURL, AssetName: a.Name}, nil
}

func findAsset(r release, name string) *asset {
	for i := range r.Assets {
		if r.Assets[i].Name == name {
			return &r.Assets[i]
		}
	}
	return nil
}

// releaseBetter ranks releases by the numeric part of the tag suffix and then
// by creation time, so a newer rolling tag also wins when numbering restarts.
func releaseBetter(a, b release, prefix string) bool {
	av, aok := numericVersion(strings.TrimPrefix(a.TagName, prefix))
	bv, bok := numericVersion(strings.TrimPrefix(b.TagName, prefix))
	if aok && bok {
		if cmp := compareNumeric(av, bv); cmp != 0 {
			return cmp > 0
		}
	}
	return a.CreatedAt.After(b.CreatedAt)
}

func numericVersion(s string) ([]int, bool) {
	s = strings.TrimLeft(s, "-_.v")
	if s == "" {
		return nil, false
	}
	parts := strings.Split(s, ".")
	out := make([]int, 0, len(parts))
	for _, p := range parts {
		digits := strings.TrimLeft(p, "0")
		if p == "" || digits == "" && p != "0" {
			return nil, false
		}
		for _, r := range p {
			if r < '0' || r > '9' {
				// Accept a trailing suffix such as "1.2.3-beta" by stopping.
				p = p[:strings.IndexFunc(p, func(r rune) bool { return r < '0' || r > '9' })]
				if p == "" {
					return nil, false
				}
				break
			}
		}
		n, err := strconv.Atoi(p)
		if err != nil {
			return nil, false
		}
		out = append(out, n)
	}
	return out, true
}

func compareNumeric(a, b []int) int {
	for i := 0; i < len(a) || i < len(b); i++ {
		var av, bv int
		if i < len(a) {
			av = a[i]
		}
		if i < len(b) {
			bv = b[i]
		}
		if av != bv {
			if av > bv {
				return 1
			}
			return -1
		}
	}
	return 0
}

// upstreamLayout returns the adopted upstream paths inside the work dir.
func upstreamLayout(workDir string) Layout {
	up := filepath.Join(workDir, "upstream")
	return Layout{
		BaseDir:   filepath.Join(up, ResourceBase),
		DictsDir:  filepath.Join(up, ResourceDicts),
		ModelDir:  filepath.Join(up, ResourceModel),
		ModelFile: filepath.Join(up, ResourceModel, ModelAssetName),
	}
}

// Layout points at adopted upstream content.
type Layout struct {
	BaseDir   string
	DictsDir  string
	ModelDir  string
	ModelFile string
}

func upstreamReady(layout Layout, spec Spec) bool {
	switch spec.Name {
	case ResourceBase:
		return dirHasFiles(layout.BaseDir)
	case ResourceDicts:
		return dirHasFiles(layout.DictsDir)
	case ResourceModel:
		st, err := os.Stat(layout.ModelFile)
		return err == nil && st.Mode().IsRegular() && st.Size() > 0
	default:
		return false
	}
}

func dirHasFiles(dir string) bool {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	for _, e := range entries {
		if !e.IsDir() {
			return true
		}
		sub := filepath.Join(dir, e.Name())
		if dirHasFiles(sub) {
			return true
		}
	}
	return false
}

// cachePaths describes the rebuildable cache of one resource.
type cachePaths struct {
	dir     string
	marker  string
	payload string
}

func cacheFor(workDir string, spec Spec) cachePaths {
	dir := filepath.Join(workDir, "cache", spec.Name)
	return cachePaths{
		dir:     dir,
		marker:  filepath.Join(dir, "marker.json"),
		payload: filepath.Join(dir, "payload", spec.AssetName),
	}
}

type marker struct {
	Resource  string    `json:"resource"`
	Version   string    `json:"version"`
	Tag       string    `json:"tag"`
	AssetName string    `json:"asset"`
	URL       string    `json:"url"`
	SHA256    string    `json:"sha256"`
	Size      int64     `json:"size"`
	FetchedAt time.Time `json:"fetched_at"`
}

func readMarker(p string) (marker, error) {
	var m marker
	data, err := os.ReadFile(p)
	if err != nil {
		return m, err
	}
	if err := json.Unmarshal(data, &m); err != nil {
		return m, fmt.Errorf("parse cache marker %s: %w", p, err)
	}
	if m.Version == "" {
		return m, fmt.Errorf("cache marker %s has no version", p)
	}
	return m, nil
}

func writeMarker(p string, m marker) error {
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	tmp, err := os.CreateTemp(filepath.Dir(p), ".marker-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(name)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(name)
		return err
	}
	if err := os.Rename(name, p); err != nil {
		os.Remove(name)
		return err
	}
	return nil
}

func fileSHA256(p string) (string, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := newSHA256()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return h.sum(), nil
}

// replaceDir atomically swaps dir into dst, keeping the previous content until
// the new content is in place.
func replaceDir(dir, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	backup := dst + ".previous"
	if err := os.RemoveAll(backup); err != nil {
		return err
	}
	existed := false
	if _, err := os.Stat(dst); err == nil {
		if err := os.Rename(dst, backup); err != nil {
			return fmt.Errorf("back up previous content %s: %w", dst, err)
		}
		existed = true
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := os.Rename(dir, dst); err != nil {
		if existed {
			_ = os.Rename(backup, dst)
		}
		return fmt.Errorf("adopt new content %s: %w", dst, err)
	}
	if existed {
		_ = os.RemoveAll(backup)
	}
	return nil
}

// swapFile moves src over dst, keeping the old file until the new one landed.
func swapFile(src, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	if err := os.Rename(src, dst); err != nil {
		return fmt.Errorf("adopt new file %s: %w", dst, err)
	}
	return nil
}

// assetBase returns the file name used for a payload archive.
func assetBase(downloadURL string) string {
	u, err := url.Parse(downloadURL)
	if err != nil {
		return path.Base(downloadURL)
	}
	return path.Base(u.Path)
}
