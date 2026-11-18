// Package config loads and validates the JSON configuration of rime-config.
//
// Paths in the configuration file are resolved relative to the directory that
// contains the configuration file. The default configuration path is
// <executable dir>/config/frontends.json, so a packaged distribution works
// without depending on the caller's working directory.
package config

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// DefaultRelativePath is the configuration location relative to the
// executable's directory.
const DefaultRelativePath = "config/frontends.json"

// DefaultPhraseExample is the user phrase template relative to the
// configuration directory.
const DefaultPhraseExample = "custom_phrase_user.dict.yaml.example"

// TriState is the three-valued "active" switch of a frontend: true, false or
// "auto" (enabled when the frontend's native platform is the current one).
type TriState int

const (
	Auto TriState = iota
	On
	Off
)

func (t TriState) String() string {
	switch t {
	case On:
		return "true"
	case Off:
		return "false"
	default:
		return "auto"
	}
}

// MarshalJSON encodes the switch as a JSON boolean or the string "auto".
func (t TriState) MarshalJSON() ([]byte, error) {
	switch t {
	case On:
		return []byte("true"), nil
	case Off:
		return []byte("false"), nil
	case Auto:
		return []byte(`"auto"`), nil
	default:
		return nil, fmt.Errorf("invalid active value: %d", int(t))
	}
}

// UnmarshalJSON accepts true, false and "auto".
func (t *TriState) UnmarshalJSON(data []byte) error {
	data = bytes.TrimSpace(data)
	if string(data) == "true" {
		*t = On
		return nil
	}
	if string(data) == "false" {
		*t = Off
		return nil
	}
	var s string
	if err := json.Unmarshal(data, &s); err != nil {
		return errors.New(`active must be true, false or "auto"`)
	}
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "auto":
		*t = Auto
	case "true", "on":
		*t = On
	case "false", "off":
		*t = Off
	default:
		return fmt.Errorf(`active must be true, false or "auto", got %q`, s)
	}
	return nil
}

// Command is a native program invocation: the executable and its argument
// vector. Arguments are passed through without shell interpretation.
type Command struct {
	Executable string   `json:"executable"`
	Args       []string `json:"args"`
}

// Commands groups the native operations a frontend may support.
type Commands struct {
	Deploy *Command `json:"deploy,omitempty"`
	Sync   *Command `json:"sync,omitempty"`
}

// Completion modes for native deploy/sync commands.
const (
	// CompletionState observes the durable files Rime writes when the work is
	// done (user.yaml last_build_time, sync snapshots).
	CompletionState = "state"
	// CompletionLog observes the completion event in the frontend log.
	CompletionLog = "log"
	// CompletionProcess treats process exit as completion.
	CompletionProcess = "process"
	// CompletionNone means the step does not run on the desktop.
	CompletionNone = "none"
)

// Frontend describes one Rime frontend or distribution target.
type Frontend struct {
	Name      string   `json:"name"`
	Kind      string   `json:"kind"`
	Active    TriState `json:"active"`
	TargetDir string   `json:"target_dir"`
	UILayer   string   `json:"ui_layer,omitempty"`
	Exclude   []string `json:"exclude,omitempty"`
	Commands  Commands `json:"commands,omitempty"`
	// SyncCompletion selects how completion of the native commands is
	// observed: "state", "log", "process" or "none".
	SyncCompletion string `json:"sync_completion,omitempty"`
	// SyncLogDir overrides the directory holding the frontend's log files.
	SyncLogDir string `json:"sync_log_dir,omitempty"`
}

// CloudSync configures the optional macOS Unison sync between the OneDrive
// Rime sync tree and the iCloud tree used by iOS frontends.
type CloudSync struct {
	Unison      string `json:"unison,omitempty"`
	OneDriveDir string `json:"one_drive_dir"`
	ICloudDir   string `json:"i_cloud_dir"`
}

// Config is the decoded and defaulted frontends.json content.
type Config struct {
	GitHubAPIBase   string     `json:"github_api_base,omitempty"`
	WorkDir         string     `json:"work_dir"`
	LocalLayer      string     `json:"local_layer,omitempty"`
	CommonUILayer   string     `json:"common_ui_layer,omitempty"`
	PhraseExample   string     `json:"phrase_example,omitempty"`
	UserPhraseFile  string     `json:"user_phrase_file,omitempty"`
	SyncWaitSeconds int        `json:"sync_wait_seconds,omitempty"`
	Frontends       []Frontend `json:"frontends"`
	CloudSync       *CloudSync `json:"cloud_sync,omitempty"`

	path string
}

// Kind describes the static properties of a supported frontend kind.
type Kind struct {
	Name     string
	Platform string
	// DefaultCommands returns the native commands of the kind. A nil command
	// means the kind cannot perform that step on this platform.
	DefaultCommands func() Commands
	// DefaultCompletion is the completion observation for native commands.
	DefaultCompletion string
}

const (
	KindSquirrel = "squirrel"
	KindWeasel   = "weasel"
	KindHamster3 = "hamster3"
	KindHamster  = "hamster"
)

// SquirrelExecutable is the system-wide Squirrel binary.
const SquirrelExecutable = "/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel"

// SquirrelCommands returns the native Squirrel commands for an executable.
func SquirrelCommands(executable string) Commands {
	return Commands{
		Deploy: &Command{Executable: executable, Args: []string{"--reload"}},
		Sync:   &Command{Executable: executable, Args: []string{"--sync"}},
	}
}

// WeaselCommands returns the native WeaselDeployer commands for an executable.
func WeaselCommands(executable string) Commands {
	return Commands{
		Deploy: &Command{Executable: executable, Args: []string{"/deploy"}},
		Sync:   &Command{Executable: executable, Args: []string{"/sync"}},
	}
}

// Kinds lists the supported frontend kinds. Hamster3 and Hamster are
// distribution targets: their own apps run deploy and sync on the device.
var Kinds = map[string]Kind{
	KindSquirrel: {
		Name:              KindSquirrel,
		Platform:          "darwin",
		DefaultCommands:   func() Commands { return SquirrelCommands(SquirrelExecutable) },
		DefaultCompletion: CompletionState,
	},
	KindWeasel: {
		Name:              KindWeasel,
		Platform:          "windows",
		DefaultCompletion: CompletionLog,
	},
	KindHamster3: {
		Name:              KindHamster3,
		Platform:          "darwin",
		DefaultCompletion: CompletionNone,
	},
	KindHamster: {
		Name:              KindHamster,
		Platform:          "darwin",
		DefaultCompletion: CompletionNone,
	},
}

// DefaultPath returns the configuration path next to the given executable.
func DefaultPath(executable string) string {
	return filepath.Join(filepath.Dir(executable), filepath.FromSlash(DefaultRelativePath))
}

// Load reads, decodes, defaults and validates a configuration file. Unknown
// fields are rejected so that typos and retired options do not pass silently.
func Load(p string) (*Config, error) {
	abs, err := filepath.Abs(p)
	if err != nil {
		return nil, fmt.Errorf("resolve config path %q: %w", p, err)
	}
	data, err := os.ReadFile(abs)
	if err != nil {
		return nil, fmt.Errorf("read config %s: %w", abs, err)
	}
	var c Config
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&c); err != nil {
		return nil, fmt.Errorf("parse config %s: %w", abs, err)
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return nil, fmt.Errorf("parse config %s: unexpected content after the JSON object", abs)
	}
	c.path = abs
	c.applyDefaults()
	if err := c.Validate(); err != nil {
		return nil, fmt.Errorf("invalid config %s: %w", abs, err)
	}
	return &c, nil
}

func (c *Config) applyDefaults() {
	if strings.TrimSpace(c.GitHubAPIBase) == "" {
		c.GitHubAPIBase = "https://api.github.com"
	}
	if c.SyncWaitSeconds == 0 {
		c.SyncWaitSeconds = 180
	}
	if strings.TrimSpace(c.UserPhraseFile) == "" {
		c.UserPhraseFile = "custom_phrase_user.dict.yaml"
	}
	if strings.TrimSpace(c.PhraseExample) == "" {
		c.PhraseExample = DefaultPhraseExample
	}
	for i := range c.Frontends {
		f := &c.Frontends[i]
		kind, ok := Kinds[f.Kind]
		if !ok {
			continue
		}
		if kind.DefaultCommands != nil {
			defaults := kind.DefaultCommands()
			if f.Commands.Deploy == nil {
				f.Commands.Deploy = defaults.Deploy
			} else {
				f.Commands.Deploy = fillCommandArgs(f.Commands.Deploy, defaults.Deploy)
			}
			if f.Commands.Sync == nil {
				f.Commands.Sync = defaults.Sync
			} else {
				f.Commands.Sync = fillCommandArgs(f.Commands.Sync, defaults.Sync)
			}
		}
		if strings.TrimSpace(f.SyncCompletion) == "" {
			f.SyncCompletion = kind.DefaultCompletion
		}
	}
	if c.CloudSync != nil && strings.TrimSpace(c.CloudSync.Unison) == "" {
		c.CloudSync.Unison = "unison"
	}
}

// fillCommandArgs keeps a user supplied executable while applying the kind's
// default argument vector when the user left it empty.
func fillCommandArgs(got, def *Command) *Command {
	if got == nil {
		return nil
	}
	if got.Executable == "" && def != nil {
		got.Executable = def.Executable
	}
	if len(got.Args) == 0 && def != nil {
		got.Args = def.Args
	}
	return got
}

// Validate checks the whole configuration without touching the filesystem
// beyond the configuration file itself.
func (c *Config) Validate() error {
	var errs []error
	add := func(format string, args ...any) {
		errs = append(errs, fmt.Errorf(format, args...))
	}

	if strings.TrimSpace(c.WorkDir) == "" {
		add("work_dir must not be empty")
	}
	if c.SyncWaitSeconds <= 0 {
		add("sync_wait_seconds must be positive")
	}
	if strings.Contains(c.UserPhraseFile, "/") || strings.Contains(c.UserPhraseFile, `\`) {
		add("user_phrase_file must be a single file name at the target root, got %q", c.UserPhraseFile)
	}
	if len(c.Frontends) == 0 {
		add("frontends needs at least one entry")
	}

	seen := map[string]bool{}
	for i, f := range c.Frontends {
		label := fmt.Sprintf("frontends[%d]", i)
		if strings.TrimSpace(f.Name) == "" {
			add("%s: name must not be empty", label)
		} else {
			label = fmt.Sprintf("frontend %q", f.Name)
			if seen[f.Name] {
				add("%s: duplicate name", label)
			}
			seen[f.Name] = true
		}
		if _, ok := Kinds[f.Kind]; !ok {
			add("%s: unknown kind %q", label, f.Kind)
		}
		if strings.TrimSpace(f.TargetDir) == "" {
			add("%s: target_dir must not be empty", label)
		}
		switch f.SyncCompletion {
		case CompletionProcess:
			switch f.Kind {
			case KindSquirrel:
				add("%s: Squirrel --reload/--sync only submit asynchronous work; sync_completion cannot be process (use state, the default)", label)
			case KindWeasel:
				add("%s: Weasel /sync and /deploy do not report task results; sync_completion cannot be process (use log, the default)", label)
			}
		case "", CompletionState, CompletionLog, CompletionNone:
		default:
			add("%s: sync_completion must be state, log, process or none, got %q", label, f.SyncCompletion)
		}
		for _, pat := range f.Exclude {
			if err := ValidatePattern(pat); err != nil {
				add("%s: invalid exclude %q: %v", label, pat, err)
			}
		}
		for step, cmd := range map[string]*Command{"deploy": f.Commands.Deploy, "sync": f.Commands.Sync} {
			if cmd == nil {
				continue
			}
			if strings.TrimSpace(cmd.Executable) == "" {
				add("%s: commands.%s.executable must not be empty", label, step)
			}
		}
		if f.SyncLogDir != "" && !filepath.IsAbs(expandHome(f.SyncLogDir)) {
			add("%s: sync_log_dir must be absolute or start with ~/", label)
		}
	}

	// Layer directories must not contain each other: a nested layer would be
	// distributed twice.
	type namedPath struct{ name, dir string }
	var layers []namedPath
	addLayer := func(name, dir string) {
		if strings.TrimSpace(dir) == "" {
			return
		}
		layers = append(layers, namedPath{name: name, dir: filepath.Clean(c.Resolve(dir))})
	}
	addLayer("local_layer", c.LocalLayer)
	addLayer("common_ui_layer", c.CommonUILayer)
	var work string
	if strings.TrimSpace(c.WorkDir) != "" {
		work = filepath.Clean(c.Resolve(c.WorkDir))
	}
	for _, f := range c.Frontends {
		addLayer(fmt.Sprintf("ui_layer of frontend %q", f.Name), f.UILayer)
	}
	for i := 0; i < len(layers); i++ {
		for j := i + 1; j < len(layers); j++ {
			a, b := layers[i], layers[j]
			if PathsOverlap(a.dir, b.dir) {
				add("%s (%s) overlaps %s (%s)", a.name, a.dir, b.name, b.dir)
			}
		}
	}
	if work != "" {
		for _, layer := range layers {
			if PathsOverlap(layer.dir, work) {
				add("%s (%s) overlaps work_dir (%s)", layer.name, layer.dir, work)
			}
		}
	}

	if c.CloudSync != nil {
		if strings.TrimSpace(c.CloudSync.OneDriveDir) == "" {
			add("cloud_sync.one_drive_dir must not be empty")
		}
		if strings.TrimSpace(c.CloudSync.ICloudDir) == "" {
			add("cloud_sync.i_cloud_dir must not be empty")
		}
		if c.CloudSync.OneDriveDir != "" && c.CloudSync.OneDriveDir == c.CloudSync.ICloudDir {
			add("cloud_sync directories must differ")
		}
	}

	return errors.Join(errs...)
}

// Path returns the configuration file itself.
func (c *Config) Path() string { return c.path }

// Dir returns the directory holding the configuration file.
func (c *Config) Dir() string { return filepath.Dir(c.path) }

// Resolve expands ~ and resolves a configuration-relative path against the
// configuration directory.
func (c *Config) Resolve(p string) string {
	p = expandHome(strings.TrimSpace(p))
	if p == "" {
		return ""
	}
	if filepath.IsAbs(p) {
		return filepath.Clean(p)
	}
	return filepath.Clean(filepath.Join(c.Dir(), filepath.FromSlash(p)))
}

// WorkPath is the tool-owned rebuildable working directory. Everything the
// tool keeps between runs (download cache, upstream, stage, Unison archive)
// lives below it and may be deleted at any time.
func (c *Config) WorkPath() string { return c.Resolve(c.WorkDir) }

// UnisonPath is the Unison archive directory (UNISON) owned by this tool.
func (c *Config) UnisonPath() string { return filepath.Join(c.WorkPath(), "unison") }

// LocalLayerPath is the repository maintained local layer.
func (c *Config) LocalLayerPath() string { return c.Resolve(c.LocalLayer) }

// CommonUILayerPath is the shared UI layer.
func (c *Config) CommonUILayerPath() string { return c.Resolve(c.CommonUILayer) }

// PhraseExamplePath is the user phrase template.
func (c *Config) PhraseExamplePath() string { return c.Resolve(c.PhraseExample) }

// Target resolves a frontend's target directory.
func (c *Config) Target(f Frontend) string { return c.Resolve(f.TargetDir) }

// FrontendUILayer resolves a frontend's UI layer.
func (c *Config) FrontendUILayer(f Frontend) string { return c.Resolve(f.UILayer) }

// ActiveFor reports whether the frontend should run on the given platform.
func (f Frontend) ActiveFor(platform string) bool {
	kind, ok := Kinds[f.Kind]
	if !ok {
		return false
	}
	switch f.Active {
	case On:
		return true
	case Off:
		return false
	default:
		return kind.Platform == platform
	}
}

// SyncLogDirectory returns the frontend log directory. Weasel writes its logs
// to %TEMP%\rime.weasel and Squirrel to $TMPDIR/rime.squirrel.
func SyncLogDirectory(f Frontend) string {
	if f.SyncLogDir != "" {
		return expandHome(f.SyncLogDir)
	}
	switch f.Kind {
	case KindWeasel:
		return filepath.Join(os.TempDir(), "rime.weasel")
	default:
		return filepath.Join(os.TempDir(), "rime.squirrel")
	}
}

// ExpandUser expands a leading ~ to the user's home directory. Native
// command executables and Unison accept it in frontends.json.
func ExpandUser(p string) string { return expandHome(p) }

func expandHome(p string) string {
	if p == "" {
		return p
	}
	if p == "~" {
		if home, err := os.UserHomeDir(); err == nil {
			return home
		}
		return p
	}
	if strings.HasPrefix(p, "~/") || strings.HasPrefix(p, `~\`) {
		home, err := os.UserHomeDir()
		if err != nil {
			return p
		}
		return filepath.Join(home, filepath.FromSlash(p[2:]))
	}
	return p
}

// PathsOverlap reports whether two cleaned paths are equal or one contains the
// other. It is used to refuse configurations where a write target would include
// or be included by a read source.
func PathsOverlap(a, b string) bool {
	a, b = CanonicalPath(a), CanonicalPath(b)
	if a == b {
		return true
	}
	return isPathWithin(a, b) || isPathWithin(b, a)
}

// CanonicalPath resolves symbolic links for the longest existing prefix of p
// and appends the components that do not exist yet. Overlap checks therefore
// compare physical locations, not only spelled paths.
func CanonicalPath(p string) string {
	p = filepath.Clean(p)
	if p == "" || p == "." {
		return p
	}
	var missing []string
	cur := p
	for {
		resolved, err := filepath.EvalSymlinks(cur)
		if err == nil {
			if len(missing) == 0 {
				return resolved
			}
			parts := make([]string, 0, len(missing)+1)
			parts = append(parts, resolved)
			for i := len(missing) - 1; i >= 0; i-- {
				parts = append(parts, missing[i])
			}
			return filepath.Clean(filepath.Join(parts...))
		}
		parent := filepath.Dir(cur)
		if parent == cur {
			return p
		}
		missing = append(missing, filepath.Base(cur))
		cur = parent
	}
}

// isPathWithin reports whether child is strictly below parent.
func isPathWithin(child, parent string) bool {
	rel, err := filepath.Rel(parent, child)
	if err != nil {
		return false
	}
	return rel != "." && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// ValidatePattern checks one simple exclude pattern. Patterns are file name
// globs, relative path globs, or directory subtrees (optionally with a trailing
// slash). Malformed globs are rejected instead of silently ignored.
func ValidatePattern(pattern string) error {
	pat := strings.TrimSpace(strings.ReplaceAll(pattern, `\`, "/"))
	if pat == "" {
		return errors.New("empty pattern")
	}
	pat = strings.TrimSuffix(pat, "/")
	if pat == "" {
		return errors.New("pattern is only a separator")
	}
	if _, err := path.Match(pat, "sample.yaml"); err != nil {
		return fmt.Errorf("bad glob: %w", err)
	}
	return nil
}

// CleanRelative normalizes a slash separated relative path and rejects
// absolute paths, parent traversal and Windows volume or UNC prefixes.
func CleanRelative(p string) (string, error) {
	p = strings.ReplaceAll(strings.TrimSpace(p), `\`, "/")
	if p == "" {
		return "", errors.New("empty path")
	}
	if strings.HasPrefix(p, "/") {
		return "", fmt.Errorf("absolute path rejected: %q", p)
	}
	if len(p) >= 2 && p[1] == ':' {
		return "", fmt.Errorf("drive path rejected: %q", p)
	}
	cleaned := path.Clean(p)
	if cleaned == "." || cleaned == ".." || strings.HasPrefix(cleaned, "../") {
		return "", fmt.Errorf("path traversal rejected: %q", p)
	}
	return cleaned, nil
}
