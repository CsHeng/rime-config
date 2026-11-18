package rimesync

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// StateProbe observes the durable files librime writes when a maintenance task
// finishes. Unlike the frontend log, these writes are visible immediately:
//
//   - deploy: the workspace update stores var/last_build_time in user.yaml
//     right after rebuilding the schemas;
//   - sync: every user dictionary is exported as
//     <sync_dir>/<installation_id>/<name>.userdb.txt.
//
// The probe only reads these files. A change only counts once it has stayed
// unchanged for the settle interval: librime writes snapshots in place, and a
// few short maintenance tasks still run after the build time is stored.
type StateProbe struct {
	mode    string
	userDir string
	// Settle is how long the completed state must stay unchanged.
	Settle time.Duration

	lastSig     string
	stableSince time.Time

	buildTime int64

	snapshotDir string
	dicts       []string
	before      map[string]time.Time
}

var reLastBuildTime = regexp.MustCompile(`(?m)^\s+last_build_time:\s*(\d+)\s*$`)

// NewStateProbe records the state before the command is submitted. mode is
// "deploy" or "sync"; userDir is the Rime user data directory.
func NewStateProbe(mode, userDir string) (*StateProbe, error) {
	if strings.TrimSpace(userDir) == "" {
		return nil, errors.New("no Rime user directory to observe")
	}
	p := &StateProbe{mode: mode, userDir: userDir}
	switch mode {
	case "deploy":
		t, err := readLastBuildTime(userDir)
		if err != nil {
			return nil, err
		}
		p.buildTime = t
	case "sync":
		dir, err := SnapshotDir(userDir)
		if err != nil {
			return nil, err
		}
		dicts, err := userDicts(userDir)
		if err != nil {
			return nil, err
		}
		if len(dicts) == 0 {
			return nil, fmt.Errorf("no *.userdb in %s, so the sync cannot be observed", userDir)
		}
		p.snapshotDir = dir
		p.dicts = dicts
		p.before = map[string]time.Time{}
		for _, d := range dicts {
			p.before[d] = modTime(p.snapshotFile(d))
		}
	default:
		return nil, fmt.Errorf("unknown completion mode %q", mode)
	}
	return p, nil
}

// BuildTime is the user.yaml last_build_time recorded before submission.
func (p *StateProbe) BuildTime() int64 { return p.buildTime }

// Done reports whether the operation submitted at since has finished, judged
// at now. The detail describes the evidence or, while pending, what is
// missing.
func (p *StateProbe) Done(since, now time.Time) (bool, string, error) {
	ready, sig, detail, err := p.observe(since)
	if err != nil || !ready {
		p.lastSig = ""
		return false, detail, err
	}
	if sig != p.lastSig {
		p.lastSig = sig
		p.stableSince = now
	}
	if now.Sub(p.stableSince) < p.Settle {
		return false, "waiting for Rime to settle: " + detail, nil
	}
	return true, detail, nil
}

func (p *StateProbe) observe(since time.Time) (bool, string, string, error) {
	switch p.mode {
	case "deploy":
		t, err := readLastBuildTime(p.userDir)
		if err != nil {
			return false, "", "", err
		}
		if t != p.buildTime && t >= since.Unix() {
			return true, strconv.FormatInt(t, 10), fmt.Sprintf("user.yaml last_build_time=%d", t), nil
		}
		return false, "", "waiting for user.yaml last_build_time to change", nil
	default:
		floor := since.Truncate(time.Second)
		var pending []string
		var sig strings.Builder
		for _, d := range p.dicts {
			st, err := os.Stat(p.snapshotFile(d))
			if err != nil || st.ModTime().Equal(p.before[d]) || st.ModTime().Before(floor) {
				pending = append(pending, d)
				continue
			}
			fmt.Fprintf(&sig, "%s:%d:%d;", d, st.Size(), st.ModTime().UnixNano())
		}
		if len(pending) > 0 {
			return false, "", fmt.Sprintf("waiting for snapshots in %s: %s", p.snapshotDir, strings.Join(pending, ", ")), nil
		}
		return true, sig.String(), fmt.Sprintf("%d user dictionary snapshots exported to %s", len(p.dicts), p.snapshotDir), nil
	}
}

func (p *StateProbe) snapshotFile(dict string) string {
	return filepath.Join(p.snapshotDir, dict+".userdb.txt")
}

func readLastBuildTime(userDir string) (int64, error) {
	data, err := os.ReadFile(filepath.Join(userDir, "user.yaml"))
	if errors.Is(err, os.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("read user.yaml: %w", err)
	}
	m := reLastBuildTime.FindSubmatch(data)
	if m == nil {
		return 0, nil
	}
	n, err := strconv.ParseInt(string(m[1]), 10, 64)
	if err != nil {
		return 0, fmt.Errorf("parse user.yaml last_build_time: %w", err)
	}
	return n, nil
}

// SnapshotDir returns <sync_dir>/<installation_id> from installation.yaml in
// the Rime user directory. sync_dir defaults to <user dir>/sync like librime.
func SnapshotDir(userDir string) (string, error) {
	f, err := os.Open(filepath.Join(userDir, "installation.yaml"))
	if err != nil {
		return "", fmt.Errorf("read installation.yaml: %w", err)
	}
	defer f.Close()
	values := map[string]string{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if line == "" || line[0] == ' ' || line[0] == '\t' || line[0] == '#' {
			continue
		}
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		values[strings.TrimSpace(key)] = yamlScalar(strings.TrimSpace(value))
	}
	if err := sc.Err(); err != nil {
		return "", fmt.Errorf("read installation.yaml: %w", err)
	}
	id := values["installation_id"]
	if id == "" {
		return "", errors.New("installation.yaml has no installation_id")
	}
	syncDir := values["sync_dir"]
	if syncDir == "" {
		syncDir = filepath.Join(userDir, "sync")
	}
	return filepath.Join(syncDir, id), nil
}

// yamlScalar decodes the plain, single-quoted and double-quoted scalar forms
// librime writes for installation.yaml values.
func yamlScalar(v string) string {
	switch {
	case len(v) >= 2 && v[0] == '"' && v[len(v)-1] == '"':
		if s, err := strconv.Unquote(v); err == nil {
			return s
		}
		return v[1 : len(v)-1]
	case len(v) >= 2 && v[0] == '\'' && v[len(v)-1] == '\'':
		return strings.ReplaceAll(v[1:len(v)-1], "''", "'")
	default:
		if i := strings.Index(v, " #"); i >= 0 {
			v = strings.TrimSpace(v[:i])
		}
		return v
	}
}

// userDicts lists the user dictionaries librime synchronizes: the *.userdb
// directories in the user data directory.
func userDicts(userDir string) ([]string, error) {
	entries, err := os.ReadDir(userDir)
	if err != nil {
		return nil, fmt.Errorf("list user dictionaries: %w", err)
	}
	var dicts []string
	for _, e := range entries {
		if e.IsDir() && strings.HasSuffix(e.Name(), ".userdb") {
			dicts = append(dicts, strings.TrimSuffix(e.Name(), ".userdb"))
		}
	}
	sort.Strings(dicts)
	return dicts, nil
}

func modTime(p string) time.Time {
	st, err := os.Stat(p)
	if err != nil {
		return time.Time{}
	}
	return st.ModTime()
}
