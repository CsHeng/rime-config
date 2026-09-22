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
- **自定义置顶短语**: User creates local `custom_phrase_user.dict.yaml` (gitignored; referenced via `custom_phrase/dictionary` in `wanxiang*.custom.yaml`, compiled at deploy time by `wanxiang_phrase.custom.yaml`)

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
custom_phrase_user.dict.yaml.example  # Tracked template for the gitignored user phrase library
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

### 自定义置顶短语 (Custom Phrase Library)

万象的置顶短语由 `wanxiang.custom_phrase` Lua filter（`lua/wanxiang/custom_phrase.lua`）驱动：
它在 init 时构造 `custom_phrase` 这个 `script_translator`，再把命中的整编码候选提到候选流最前。

- 词库入口：`wanxiang*.custom.yaml` 中的 `custom_phrase/dictionary: custom_phrase_user`（runtime）。
- 编译入口：`wanxiang_phrase.custom.yaml`（及 `wanxiang_phrase_t9.custom.yaml`）的 `translator/dictionary`；
  `wanxiang.schema.yaml` 的 `schema/dependencies` 包含 `wanxiang_phrase`，部署时 `SchemaUpdate` 才编译该词库。
- 用户词库：`custom_phrase_user.dict.yaml`（gitignored，缺失时 `update.sh`/`update.ps1` 从 `.example` 生成），
  行格式 `<短语><TAB><编码><TAB><权重>`，编码可为任意字母串。
- 不要使用 `custom_phrase/user_dict`：万象的 `custom_phrase` 组件带 `enable_user_dict: false`，
  librime 的 `UserDictionaryComponent::Create` 会直接返回 NULL，该键被完全忽略（历史 bug 根因）。
- 修改短语后必须触发部署（`Squirrel --reload` / `WeaselDeployer /deploy` / `cmd/update.sh`），
  编译产物为 `build/custom_phrase_user.table.bin` + `build/custom_phrase_user.reverse.bin`。

### iOS Theme System
- Format: Hamster .cskin (YAML-based)
- Structure: `config.yaml` + layout files (portrait/landscape, light/dark)
- Tooling: `hamster3-ios-csheng-skin` skill for maintenance

### iOS (Hamster3/元书) 文件流向
重新部署/同步时的流转：`iCloud → 应用`（覆盖合并）→ RIME（部署或同步）→ `应用 → 键盘`（整体回写）。
- `键盘 → 应用` 仅复制匹配 `include_keyboard_rime_files.txt` 的文件，且先删除应用侧 `*.userdb` 目录；
  该文件必须包含 `.*[.]userdb.*$`（仓库：`cmd/hamster3/include_keyboard_rime_files.txt`），
  否则每次部署都会清空手机自造词；禁止写 `^.*[.]custom.*$`（会让键盘旧 patch 覆盖 iCloud 新 patch）。
- 自造词合并只发生在「同步」（合并 `RimeUserSync/*/<dict>.userdb.txt`）；部署不合并。
- 手机的 patch/方案来自 iCloud 方案目录，因此仓库改完必须让手机执行一次「重新部署」。

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
- Custom phrases: after a deploy, `~/Library/Rime/build/custom_phrase_user.table.bin` must be newer than
  `custom_phrase_user.dict.yaml`; functional check = typing `gsdz` returns the phrase as candidate 0

### 无 IME 验证置顶短语（可选）
在临时目录用 Squirrel 自带的 librime 直接查候选，不动真实 `~/Library/Rime`：

1. `otool -L "/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel" | grep librime` 取版本（current version 字段）
2. 同 tag 取 `src/rime_api.h`（https://github.com/rime/librime），写个 ~40 行 C 程序：
   `rime->setup({shared_data_dir,user_data_dir,staging_dir=<临时目录>}) -> initialize -> create_session ->
   select_schema("wanxiang") -> simulate_key_sequence("gsdz") -> get_context` 打印 `menu.candidates`
3. `clang -o probe probe.c -I<rime_api.h 目录> "/Library/Input Methods/Squirrel.app/Contents/Frameworks/librime.1.dylib" -Wl,-rpath,"/Library/Input Methods/Squirrel.app/Contents/Frameworks"`
4. 把 `~/Library/Rime`（排除 `*.userdb`、`*.gram`、`custom/`）rsync 到临时目录，在临时目录里运行（不要调 `start_maintenance`，直接用现成 build/ 产物）
- Platform redeploy: confirm input method reloaded

### Testing
- Test schema changes: deploy to single platform first
- Verify input behavior: test all schema variants
- Cross-platform: test on macOS and Windows before committing
