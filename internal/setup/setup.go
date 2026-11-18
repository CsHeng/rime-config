// Package setup detects installed Rime frontends and cloud sync directories so
// that frontends.json starts from the local machine's real paths instead of a
// hand-edited template.
//
// Detection is best effort: a missing frontend is reported and omitted, never
// guessed. Paths inside the user's home directory are written with "~" so the
// generated configuration can be shared without leaking a user name.
package setup

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"unicode"

	"rime-config-go/internal/config"
)

// Options controls one setup run. Test hooks are the SquirrelApps and
// ProgramRoots fields; production callers leave them empty.
type Options struct {
	Home         string
	Platform     string
	ConfigPath   string
	DryRun       bool
	Force        bool
	Getenv       func(string) string
	SquirrelApps []string
	ProgramRoots []string
}

// Result is the outcome of a setup run. ConfigJSON is always populated so a
// dry run can print exactly what would be written.
type Result struct {
	ConfigPath string
	ConfigJSON []byte
	Written    bool
	Notes      []string
}

// Run detects frontends, builds a configuration and writes it unless DryRun is
// set. An existing configuration is left untouched unless Force is set, so a
// repeated setup never discards hand edits.
func Run(o Options) (*Result, error) {
	if o.Platform == "" {
		o.Platform = runtime.GOOS
	}
	if o.Home == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, fmt.Errorf("cannot determine the home directory: %w", err)
		}
		o.Home = home
	}
	if strings.TrimSpace(o.ConfigPath) == "" {
		return nil, errors.New("missing config path")
	}
	if o.Getenv == nil {
		o.Getenv = os.Getenv
	}

	var notes []string
	var frontends []config.Frontend
	switch o.Platform {
	case "darwin":
		if f, n, ok := detectSquirrel(o); ok {
			frontends = append(frontends, f)
			notes = append(notes, n...)
		} else {
			notes = append(notes, "Squirrel not found (checked /Library/Input Methods/Squirrel.app and ~/Library/Input Methods/Squirrel.app)")
		}
		if f, n, ok := detectHamster3(o); ok {
			frontends = append(frontends, f)
			notes = append(notes, n...)
		}
	case "windows":
		if f, n, ok := detectWeasel(o); ok {
			frontends = append(frontends, f)
			notes = append(notes, n...)
		} else {
			notes = append(notes, "WeaselDeployer.exe not found (checked Rime under %PROGRAMFILES%, %PROGRAMFILES(X86)% and %LOCALAPPDATA%)")
		}
	default:
		return nil, fmt.Errorf("frontend detection is not supported on %s; write the config by hand", o.Platform)
	}
	if len(frontends) == 0 {
		return nil, errors.New("no Rime frontend found; install Squirrel or Weasel and run setup again")
	}

	cloud, cloudNotes := detectCloud(o)
	notes = append(notes, cloudNotes...)

	cfg := config.Config{
		GitHubAPIBase:  "https://api.github.com",
		WorkDir:        "../build",
		LocalLayer:     "local",
		CommonUILayer:  "common",
		PhraseExample:  config.DefaultPhraseExample,
		UserPhraseFile: "custom_phrase_user.dict.yaml",
		Frontends:      frontends,
		CloudSync:      cloud,
	}
	data, err := json.MarshalIndent(&cfg, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("generate config: %w", err)
	}
	data = append(data, '\n')
	if err := validate(data); err != nil {
		return nil, fmt.Errorf("generated config failed validation: %w", err)
	}

	res := &Result{ConfigPath: o.ConfigPath, ConfigJSON: data}
	exists := false
	if st, err := os.Stat(o.ConfigPath); err == nil {
		exists = st.Mode().IsRegular()
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("check config file: %w", err)
	}

	switch {
	case o.DryRun:
		notes = append(notes, "dry-run: config not written")
		if exists {
			notes = append(notes, "config already exists; rebuilding it needs --force")
		}
	case exists && !o.Force:
		notes = append(notes, fmt.Sprintf("config already exists, left unchanged: %s", o.ConfigPath))
		notes = append(notes, "to rebuild it from detection run: mise run setup -- --force (the old file is kept as .bak)")
	default:
		if exists {
			backup := o.ConfigPath + ".bak"
			if err := copyRegular(o.ConfigPath, backup); err != nil {
				return nil, fmt.Errorf("back up existing config: %w", err)
			}
			notes = append(notes, fmt.Sprintf("previous config kept as %s", backup))
		}
		if err := writeFile(o.ConfigPath, data); err != nil {
			return nil, err
		}
		res.Written = true
		notes = append(notes, fmt.Sprintf("config written: %s", o.ConfigPath))
	}
	res.Notes = notes
	return res, nil
}

// validate parses the generated JSON with the real loader so schema drift is
// caught before the file is written. The short-lived copy is removed at once.
func validate(data []byte) error {
	f, err := os.CreateTemp("", "rime-config-setup-*.json")
	if err != nil {
		return err
	}
	name := f.Name()
	defer os.Remove(name)
	if _, err := f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	_, err = config.Load(name)
	return err
}

func writeFile(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("create config directory: %w", err)
	}
	f, err := os.CreateTemp(dir, ".frontends-*.json")
	if err != nil {
		return fmt.Errorf("write config: %w", err)
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if _, err := f.Write(data); err != nil {
		f.Close()
		return fmt.Errorf("write config: %w", err)
	}
	if err := f.Chmod(0o644); err != nil {
		f.Close()
		return fmt.Errorf("set config permissions: %w", err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("write config: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		return fmt.Errorf("write config: %w", err)
	}
	return nil
}

func copyRegular(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0o644)
}

func detectSquirrel(o Options) (config.Frontend, []string, bool) {
	candidates := o.SquirrelApps
	if len(candidates) == 0 {
		candidates = []string{
			filepath.Join(o.Home, "Library", "Input Methods", "Squirrel.app"),
			"/Library/Input Methods/Squirrel.app",
		}
	}
	for _, app := range candidates {
		st, err := os.Stat(app)
		if err != nil || !st.IsDir() {
			continue
		}
		exe := filepath.Join(app, "Contents", "MacOS", "Squirrel")
		if st, err := os.Stat(exe); err != nil || st.IsDir() {
			continue
		}
		exePath := tilde(o.Home, exe)
		f := config.Frontend{
			Name:      "squirrel",
			Kind:      config.KindSquirrel,
			Active:    config.Auto,
			TargetDir: "~/Library/Rime",
			UILayer:   "frontends/squirrel",
			Exclude:   []string{"*.log", "*.tmp"},
			Commands:  config.SquirrelCommands(exePath),
		}
		notes := []string{fmt.Sprintf("found Squirrel: %s", tilde(o.Home, app))}
		if _, err := os.Stat(filepath.Join(o.Home, "Library", "Rime")); err != nil {
			notes = append(notes, "target ~/Library/Rime does not exist yet; the first update creates it (start Squirrel once if it never ran)")
		}
		return f, notes, true
	}
	return config.Frontend{}, nil, false
}

func detectWeasel(o Options) (config.Frontend, []string, bool) {
	roots := o.ProgramRoots
	if len(roots) == 0 {
		if v := o.Getenv("PROGRAMFILES"); v != "" {
			roots = append(roots, filepath.Join(v, "Rime"))
		}
		if v := o.Getenv("PROGRAMFILES(X86)"); v != "" {
			roots = append(roots, filepath.Join(v, "Rime"))
		}
		if v := o.Getenv("LOCALAPPDATA"); v != "" {
			roots = append(roots, filepath.Join(v, "Programs", "Rime"))
		}
	}
	var found []string
	for _, root := range roots {
		matches, err := filepath.Glob(filepath.Join(root, "weasel-*", "WeaselDeployer.exe"))
		if err != nil {
			continue
		}
		found = append(found, matches...)
	}
	if len(found) == 0 {
		return config.Frontend{}, nil, false
	}
	sort.Slice(found, func(i, j int) bool { return versionLess(found[i], found[j]) })
	exe := found[len(found)-1]
	f := config.Frontend{
		Name:      "weasel",
		Kind:      config.KindWeasel,
		Active:    config.Auto,
		TargetDir: "~/AppData/Roaming/Rime",
		UILayer:   "frontends/weasel",
		Exclude:   []string{"*.log", "*.tmp"},
		Commands:  config.WeaselCommands(exe),
	}
	notes := []string{
		fmt.Sprintf("found Weasel: %s", exe),
		"Weasel /deploy results cannot be verified: update with --no-redeploy, then deploy from the tray menu",
	}
	if len(found) > 1 {
		notes = append(notes, fmt.Sprintf("found %d Weasel installations; using the highest version (edit the config if that is wrong)", len(found)))
	}
	return f, notes, true
}

// versionLess compares the numeric components of weasel-<version> directories
// so 0.17.10 sorts above 0.17.4 instead of lexicographically.
func versionLess(a, b string) bool {
	na, nb := versionNumbers(a), versionNumbers(b)
	for i := 0; i < len(na) && i < len(nb); i++ {
		if na[i] != nb[i] {
			return na[i] < nb[i]
		}
	}
	if len(na) != len(nb) {
		return len(na) < len(nb)
	}
	return a < b
}

func versionNumbers(path string) []int {
	base := filepath.Base(filepath.Dir(path))
	parts := strings.FieldsFunc(base, func(r rune) bool { return !unicode.IsDigit(r) })
	nums := make([]int, 0, len(parts))
	for _, part := range parts {
		n, err := strconv.Atoi(part)
		if err != nil {
			continue
		}
		nums = append(nums, n)
	}
	return nums
}

// detectHamster3 finds the Hamster3 iCloud user data directory, for example
// iCloud~com~ihsiao~apps~Hamster3/Documents/RimeUserData/<schema dir>.
func detectHamster3(o Options) (config.Frontend, []string, bool) {
	if o.Platform != "darwin" {
		return config.Frontend{}, nil, false
	}
	base := filepath.Join(o.Home, "Library", "Mobile Documents")
	entries, err := os.ReadDir(base)
	if err != nil {
		return config.Frontend{}, nil, false
	}
	var dirs []string
	for _, e := range entries {
		if !e.IsDir() || !strings.Contains(strings.ToLower(e.Name()), "hamster3") {
			continue
		}
		docs := filepath.Join(base, e.Name(), "Documents")
		if matches, err := filepath.Glob(filepath.Join(docs, "RimeUserData", "*")); err == nil {
			dirs = append(dirs, matches...)
		}
		dirs = append(dirs, filepath.Join(docs, "Rime"))
	}
	var found []string
	for _, dir := range dirs {
		if isDir(dir) && looksLikeRimeUserDir(dir) {
			found = append(found, dir)
		}
	}
	if len(found) == 0 {
		return config.Frontend{}, nil, false
	}
	// Prefer a directory that already holds the Wanxiang schema, then the
	// shortest path.
	sort.Slice(found, func(i, j int) bool {
		wi, wj := isFile(filepath.Join(found[i], "wanxiang.schema.yaml")), isFile(filepath.Join(found[j], "wanxiang.schema.yaml"))
		if wi != wj {
			return wi
		}
		return len(found[i]) < len(found[j])
	})
	dir := found[0]
	f := config.Frontend{
		Name:      "hamster3",
		Kind:      config.KindHamster3,
		Active:    config.Auto,
		TargetDir: tilde(o.Home, dir),
		UILayer:   "frontends/hamster3",
		Exclude:   []string{"*.log", "*.tmp"},
	}
	notes := []string{fmt.Sprintf("found Hamster3: %s (the app deploys and syncs on the device)", tilde(o.Home, dir))}
	if len(found) > 1 {
		notes = append(notes, fmt.Sprintf("found %d Hamster3 user directories; using %s (edit the config if that is wrong)", len(found), tilde(o.Home, dir)))
	}
	return f, notes, true
}

// looksLikeRimeUserDir accepts either an already initialized Rime user
// directory or a schema directory; an empty iCloud placeholder is not enough.
func looksLikeRimeUserDir(dir string) bool {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := strings.ToLower(e.Name())
		if strings.HasSuffix(name, ".yaml") || strings.HasSuffix(name, ".yml") {
			return true
		}
	}
	return false
}

func detectCloud(o Options) (*config.CloudSync, []string) {
	if o.Platform != "darwin" {
		return nil, nil
	}
	oneDrive, oneNotes := detectOneDrive(o)
	iCloud, iCloudNotes := detectICloud(o)
	notes := append(oneNotes, iCloudNotes...)
	if oneDrive == "" || iCloud == "" {
		if oneDrive == "" && iCloud == "" {
			notes = append(notes, "no OneDrive/iCloud Rime sync folder found; cloud_sync not written")
		}
		if oneDrive == "" && iCloud != "" {
			notes = append(notes, "only the iCloud sync folder was found; cloud_sync not written (add the OneDrive folder to use --cloud-sync)")
		}
		if iCloud == "" && oneDrive != "" {
			notes = append(notes, "only the OneDrive sync folder was found; cloud_sync not written (add the iCloud folder to use --cloud-sync)")
		}
		return nil, notes
	}
	notes = append(notes, "found both sync folders; cloud_sync written (check them before using --cloud-sync)")
	return &config.CloudSync{
		OneDriveDir: tilde(o.Home, oneDrive),
		ICloudDir:   tilde(o.Home, iCloud),
	}, notes
}

func detectICloud(o Options) (string, []string) {
	base := filepath.Join(o.Home, "Library", "Mobile Documents", "com~apple~CloudDocs")
	for _, name := range []string{"RimeUserSync", "RimeSync"} {
		dir := filepath.Join(base, name)
		if isDir(dir) && looksLikeRimeSyncDir(dir) {
			return dir, []string{fmt.Sprintf("found iCloud Rime sync folder: %s", tilde(o.Home, dir))}
		}
	}
	entries, err := os.ReadDir(base)
	if err != nil {
		return "", nil
	}
	var found []string
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		dir := filepath.Join(base, e.Name())
		if looksLikeRimeSyncDir(dir) {
			found = append(found, dir)
		}
	}
	if len(found) == 0 {
		return "", nil
	}
	sort.Slice(found, func(i, j int) bool { return len(found[i]) < len(found[j]) })
	notes := []string{fmt.Sprintf("found iCloud Rime sync folder: %s", tilde(o.Home, found[0]))}
	if len(found) > 1 {
		notes = append(notes, fmt.Sprintf("found %d iCloud sync folder candidates; using the shortest path (edit the config if that is wrong)", len(found)))
	}
	return found[0], notes
}

func detectOneDrive(o Options) (string, []string) {
	var roots []string
	var seen []os.FileInfo
	addRoot := func(path string) {
		st, err := os.Stat(path)
		if err != nil {
			return
		}
		for _, prev := range seen {
			if os.SameFile(st, prev) {
				return
			}
		}
		seen = append(seen, st)
		roots = append(roots, path)
	}
	// Prefer the CloudStorage location so a legacy ~/OneDrive symlink does not
	// win with a shorter path; both point at the same tree.
	for _, pattern := range []string{
		filepath.Join(o.Home, "Library", "CloudStorage", "OneDrive-*"),
		filepath.Join(o.Home, "OneDrive*"),
	} {
		matches, err := filepath.Glob(pattern)
		if err != nil {
			continue
		}
		sort.Strings(matches)
		for _, m := range matches {
			addRoot(m)
		}
	}
	var found []string
	for _, root := range roots {
		if dir := findOneDriveSyncDir(root); dir != "" {
			found = append(found, dir)
		}
	}
	if len(found) == 0 {
		return "", nil
	}
	sort.Slice(found, func(i, j int) bool { return len(found[i]) < len(found[j]) })
	notes := []string{fmt.Sprintf("found OneDrive Rime sync folder: %s", tilde(o.Home, found[0]))}
	if len(found) > 1 {
		notes = append(notes, fmt.Sprintf("found %d OneDrive sync folders; using the shortest path (edit the config if that is wrong)", len(found)))
	}
	return found[0], notes
}

// findOneDriveSyncDir prefers the conventional Apps/RimeSync layout. The
// installation subdirectories below a sync root also contain *.userdb.txt, so
// only the conventional names and the root itself are considered.
func findOneDriveSyncDir(root string) string {
	for _, rel := range []string{"Apps/RimeSync", "Apps/RimeUserSync", "RimeSync", "RimeUserSync", ""} {
		dir := root
		if rel != "" {
			dir = filepath.Join(root, filepath.FromSlash(rel))
		}
		if isDir(dir) && looksLikeRimeSyncDir(dir) {
			return dir
		}
	}
	return ""
}

// looksLikeRimeSyncDir recognizes a Rime sync tree by installation.yaml or by
// user dict snapshots directly below it or one installation level down.
func looksLikeRimeSyncDir(dir string) bool {
	if isFile(filepath.Join(dir, "installation.yaml")) {
		return true
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	for _, e := range entries {
		if e.IsDir() {
			if hasUserdbSnapshot(filepath.Join(dir, e.Name())) {
				return true
			}
			continue
		}
		if strings.HasSuffix(strings.ToLower(e.Name()), ".userdb.txt") {
			return true
		}
	}
	return false
}

func hasUserdbSnapshot(dir string) bool {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(strings.ToLower(e.Name()), ".userdb.txt") {
			return true
		}
	}
	return false
}

func isDir(path string) bool {
	st, err := os.Stat(path)
	return err == nil && st.IsDir()
}

func isFile(path string) bool {
	st, err := os.Stat(path)
	return err == nil && st.Mode().IsRegular()
}

// tilde replaces the home prefix so generated configurations do not carry a
// user name. Paths outside the home directory stay absolute.
func tilde(home, path string) string {
	home = filepath.Clean(home)
	path = filepath.Clean(path)
	if path == home {
		return "~"
	}
	rel, err := filepath.Rel(home, path)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return filepath.ToSlash(path)
	}
	return "~/" + filepath.ToSlash(rel)
}
