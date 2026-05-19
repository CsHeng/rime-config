# AI Agent Instructions

For project overview and setup instructions, see [README.md](./README.md).

## Project Context

Multi-platform Rime input method configuration repository. Tracks local customization layer that survives upstream updates, supports cross-device reuse. Upstream content is rebuildable via scripts.

**Schema:** Wanxiang (万象) with variants (reverse, mixedcode, english, t9)

**Platforms:**
- macOS: Squirrel (鼠鬚管)
- Windows: Weasel (小狼毫)
- iOS: Hamster/Hamster3 (仓输入法)

**Definitions:**
- **frontend**: Rime UI shell (`squirrel`=macOS / `weasel`=Windows / `hamster`/`hamster3`=iOS)
- **自定义置顶短语**: User creates local `custom_phrase_user.txt` (referenced via `wanxiang*.custom.yaml` `custom_phrase/user_dict`, path adjusted per user Rime directory)

## Repository Layout

```
cmd/                       # Platform-specific configurations and scripts
  ├── common/             # Shared configuration templates
  ├── squirrel/           # macOS Squirrel configs + rsync filters
  ├── weasel/             # Windows Weasel configs + rsync filters
  ├── hamster/            # iOS Hamster configs (legacy)
  ├── hamster3/           # iOS Hamster 3 configs + rsync filters
  ├── frontends.yaml.tmpl # Frontend platform definitions template
  ├── frontends.yaml      # User-local frontend config (not tracked)
  ├── frontends.sh        # Frontend resolution helpers (yq wrapper)
  ├── sync-userdict.sh    # User dictionary cloud sync (Unison)
  ├── update.sh           # Update script (bash, rsync-based)
  └── update.ps1          # Update script (PowerShell 7, native file ops)
build/                    # Build artifacts (not tracked)
  ├── cache/              # Download cache
  ├── markers/            # Version markers
  ├── upstream/           # Upstream unpacked files (rsync source)
  └── stage/<frontend>/   # Per-frontend merged staging directories
resources/                # Additional resources
  └── ios-csheng/         # iOS Hamster theme (.cskin format)
*.custom.yaml             # Root-level schema customizations
```

**Required Files:**
- `cmd/frontends.yaml.tmpl`: Frontend config template
- `cmd/frontends.sh`: YAML parsing wrapper (yq-based, provides bash functions)
- `cmd/update.sh`: Daily update script (macOS/Linux/Git Bash, rsync-based)
- `cmd/update.ps1`: Daily update script (Windows PowerShell 7, native file ops)
- `cmd/sync-userdict.sh`: User dictionary cloud sync (Unison: iCloud ↔ OneDrive)
- Per-frontend rsync filters: `cmd/<frontend>/update-rsync.filter` (update) / `bootstrap-rsync.filter` (init)

## Coding Standards

### Shell Scripts
- Shebang: `#!/bin/bash` for update.sh (existing convention)
- Error handling: `set -euo pipefail`
- Path resolution: absolute paths via `$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)`
- Color output: exported color codes (GREEN, YELLOW, RED, NC)
- Dependency checks: validate required tools (yq, rsync, unison) before use
- Windows compatibility: Git Bash style paths (`/c/...`), never `C:\...` or `C:...`

### PowerShell Scripts
- Version: PowerShell 7+ (update.ps1)
- Error handling: `$ErrorActionPreference = 'Stop'`
- Native file operations: no rsync dependency
- Filter engine: custom implementation for rsync filter compatibility

### YAML Configuration
- Rime schema files: `.schema.yaml`, `.dict.yaml`, `.custom.yaml`
- Frontend config: `cmd/frontends.yaml` (platform definitions, target paths, deployment commands)
- iOS theme: `resources/ios-csheng/config.yaml` (.cskin format)
- Validation: use `yq` (mikefarah/yq v4) for parsing

### File Naming
- Schema files: `wanxiang*.schema.yaml`, `wanxiang*.dict.yaml`
- Custom overrides: `*.custom.yaml`
- Platform configs: `{squirrel,weasel,hamster3}.custom.yaml`

## Workflow Preferences

### Setup (First-Time Configuration)

User must create local config file:
```bash
cp cmd/frontends.yaml.tmpl cmd/frontends.yaml
# Edit cmd/frontends.yaml: set target_dir and active flags
```

`cmd/frontends.yaml` is not tracked, user can modify per local needs.

### Init Flow (Optional)

`cmd/update.sh --init` (internally calls `rsync_bootstrap_templates`) initializes template files from `cmd/<frontend>/` to target:
- Filter rules: `cmd/<frontend>/bootstrap-rsync.filter`
- Uses `rsync` with `--ignore-existing` (only writes missing files)

### Update Flow (Daily)

`cmd/update.sh` core constraints:

1. **Upstream resources downloaded once**, output to repo cache:
   - `build/cache/`: download cache
   - `build/markers/`: version markers
   - `build/upstream/`: unpacked upstream directory (rsync upstream source)

2. **Per active frontend**, generate rebuildable merged directory:
   - `build/stage/<frontend>/` = upstream + local common layer + (optional) UI layer
   - Directory can be deleted and regenerated anytime

3. **Frontend activation** (configured in `cmd/frontends.yaml`):
   - `active: auto` (default): auto-run when platform detected
   - `active: true`: force run, supports multiple frontends simultaneously
   - `active: false`: disabled

   Example: deploy to both squirrel and hamster3 on macOS:
   ```yaml
   frontends:
     squirrel:
       active: auto  # darwin auto-detect
     hamster3:
       active: true  # force enable
   ```

4. **Frontend resources + downloaded resources** must pass through per-frontend filter via single `rsync`:
   - `rsync build/stage/<frontend>/ -> <target>/` + `--filter="merge cmd/<frontend>/update-rsync.filter"`
   - Default: no `--delete` (manual cleanup with `--dry-run --delete` preview recommended)

5. **Post-update Hooks**:
   - Auto-execute `redeploy_cmd` per `cmd/frontends.yaml` (default on, disable with `--no-redeploy`)
   - Auto-execute Rime userdict sync (`sync_cmd`, default on, disable with `--no-sync`)
   - Optional: `--cloud-sync` triggers cloud userdict sync (iCloud ↔ OneDrive)

### Userdict Cloud Sync Flow (Optional)

`cmd/sync-userdict.sh` uses Unison for iCloud ↔ OneDrive bidirectional sync:

```
Windows (weasel) ↔ OneDrive ↔ macOS (squirrel) ↔ iCloud ↔ iOS (hamster/hamster3)
```

**Configuration (`cmd/frontends.yaml`):**
```yaml
userdict_sync:
  icloud: ~/Library/Mobile Documents/com~apple~CloudDocs/RimeUserSync
  onedrive:
    darwin: ~/Library/CloudStorage/OneDrive-Personal/Apps/RimeSync
    windows: /c/Users/<User>/OneDrive/Apps/RimeSync
```

**sync_dir structure** (distinguished by `installation_id`):
```
RimeUserSync/
├── Squirrel-CsHeng's-Macbook-M1-Max/
├── Weasel-CsHeng's-PC/
├── Hamster-xxx/
└── ...
```

**Dependency:** `unison` (macOS: `brew install unison`)

### Git Workflow

- Upstream content downloadable/generatable via `update.sh`/`update.ps1`: not tracked
- Only track local layer not overwritten by update (patches/dictionaries) and scripts/configs
- `cmd/frontends.yaml`: not tracked (user-local config, copied from `.tmpl`)

## Architecture Notes

### Multi-Platform Strategy
- Single source of truth: root `*.custom.yaml` files
- Platform-specific overrides: `cmd/{platform}/*.custom.yaml`
- Build system: `cmd/update.sh` merges and stages configs per platform
- Deployment: rsync with platform-specific filters (`rsync_filter` in frontends.yaml)

### Schema Variants
- Base: `wanxiang.schema.yaml`
- Reverse lookup: `wanxiang_reverse.schema.yaml`
- Mixed code: `wanxiang_mixedcode.schema.yaml`
- English mode: `wanxiang_english.schema.yaml`
- T9 mode: `wanxiang_t9.schema.yaml`

### iOS Theme System
- Format: Hamster .cskin (YAML-based)
- Structure: `config.yaml` + layout files (portrait/landscape, light/dark)
- Tooling: `hamster3-ios-csheng-skin` skill for maintenance

## Tool Requirements

- `yq` (mikefarah/yq v4): YAML parsing and manipulation
- `rsync`: configuration synchronization (bash scripts)
- `unison`: cloud userdict sync (optional)
- `bash`: script execution (Git Bash on Windows)
- Platform-specific:
  - macOS: Squirrel installed
  - Windows: Weasel installed, Git Bash or MSYS2
  - iOS: Hamster app installed

## Validation

### Pre-Commit Checks
- YAML syntax: `yq eval '.' <file>` (exit 0 = valid)
- Path format (Windows): verify `/c/...` style in `cmd/frontends.yaml`
- Rsync filter files: verify referenced files exist

### Deployment Verification
- Staged configs: check `build/stage/{platform}/` after `cmd/update.sh`
- Target sync: verify files copied to target directories
- Platform redeploy: confirm input method reloaded

### Testing
- Test schema changes: deploy to single platform first
- Verify input behavior: test all schema variants
- Cross-platform: test on macOS and Windows before committing
