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
  ├── frontends.json.tmpl # Frontend platform definitions template (JSON)
  ├── frontends.json      # User-local frontend config (not tracked)
  ├── frontends.sh        # Frontend resolution helpers (jq-based bash functions)
  ├── sync-userdict.sh    # User dictionary cloud bridge (macOS, Unison)
  ├── update.sh           # Update script (bash, rsync-based)
  ├── update.ps1          # Update script (PowerShell 7, native file ops; Windows entry)
  └── tests/              # Scenario tests (run-tests.sh / run-tests.ps1, see tests/README.md)
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
- `cmd/frontends.json.tmpl`: Frontend config template (single source of truth shared by both entries)
- `cmd/frontends.sh`: JSON parsing wrapper (jq-based, provides bash functions)
- `cmd/update.sh`: Daily update script (macOS/Linux/Git Bash, rsync-based)
- `cmd/update.ps1`: Daily update script (Windows PowerShell 7, native file ops, no yq/rsync/jq/curl/unzip)
- `cmd/sync-userdict.sh`: User dictionary cloud bridge (macOS-only, Unison: iCloud ↔ OneDrive)
- Per-frontend rsync filters: `cmd/<frontend>/update-rsync.filter` (update) / `bootstrap-rsync.filter` (init)

## Coding Standards

### Shell Scripts
- Shebang: `#!/bin/bash` for update.sh (existing convention)
- Error handling: `set -euo pipefail`
- Path resolution: absolute paths via `$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)`
- Color output: exported color codes (GREEN, YELLOW, RED, NC)
- Dependency checks: validate required tools per operation (jq for config, rsync only when staging, curl/jq/unzip only when downloading, unison only for the cloud bridge)
- Windows compatibility: Git Bash style paths (`/c/...`), never `C:\...` or `C:...`

### PowerShell Scripts
- Version: PowerShell 7+ (update.ps1)
- Error handling: `$ErrorActionPreference = 'Stop'`
- Native file operations: no rsync dependency
- Filter engine: custom implementation for rsync filter compatibility

### Configuration Formats
- Rime schema files: `.schema.yaml`, `.dict.yaml`, `.custom.yaml` — validate with `yq` (mikefarah/yq v4)
- Frontend config: `cmd/frontends.json` (platform definitions, target paths, `redeploy_cmd`/`sync_cmd` as `{executable, args}` objects) — validate with `jq`
- iOS theme: `resources/ios-csheng/config.yaml` (.cskin format)
- The two update entries share one JSON config: PowerShell reads it natively (`ConvertFrom-Json`, single read + validation), bash via `frontends.sh` (jq). No YAML fallback at runtime.

### File Naming
- Schema files: `wanxiang*.schema.yaml`, `wanxiang*.dict.yaml`
- Custom overrides: `*.custom.yaml`
- Platform configs: `{squirrel,weasel,hamster3}.custom.yaml`

## Workflow Preferences

### Setup (First-Time Configuration)

User must create local config file:
```bash
cp cmd/frontends.json.tmpl cmd/frontends.json
# Edit cmd/frontends.json: set target_dir and active flags
```

`cmd/frontends.json` is not tracked, user can modify per local needs. Both entries accept
`--config <file>` / `-Config <file>` (relative to caller cwd); `.env` (e.g. `GITHUB_TOKEN`) is loaded
only from the selected config directory. Migration from the old `frontends.yaml` is a documented manual
one-time step (see cmd/README.md); runtime has no YAML fallback.

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

3. **Frontend activation** (configured in `cmd/frontends.json`):
   - `"active": "auto"` (default): auto-run when platform detected
   - `"active": true`: force run, supports multiple frontends simultaneously
   - `"active": false`: disabled

   Example: deploy to both squirrel and hamster3 on macOS:
   ```json
   {"frontends": {
     "squirrel": {"active": "auto"},
     "hamster3": {"active": true}
   }}
   ```

4. **Frontend resources + downloaded resources** must pass through per-frontend filter via single `rsync`:
   - `rsync build/stage/<frontend>/ -> <target>/` + `--filter="merge cmd/<frontend>/update-rsync.filter"`
   - Default: no `--delete` (manual cleanup with `--dry-run --delete` preview recommended)
   - Target validations run before any target write: `--target`/`-Target` override only with a single active frontend; non-dry-run override must disable redeploy+sync; stage/template/upstream overlap with target rejected; duplicate targets across frontends rejected. The PowerShell filter engine is directory-aware (excluded dirs prune whole subtrees for copy AND delete), errors on unsupported rule forms, and preserves `user.yaml`/`installation.yaml`/nested `*.userdb/`/`build/`/`lua/tips/`/frontend excludes under copy, explicit `-Delete`, and dry-run.
   - dry-run touches only rebuildable cache/stage: no target creation/modification, no user phrase file generation (example goes into stage only), no hooks/bridge.

5. **Post-update Hooks**:
   - Auto-execute `redeploy_cmd` per `cmd/frontends.json` (default on, disable with `--no-redeploy`/`-NoRedeploy`) as `{executable, args}` objects invoked natively (no `sh -c`/`Invoke-Expression`), exit codes checked and reported as frontend|stage|exit summaries with nonzero overall exit on failure
   - Auto-execute Rime userdict sync (`sync_cmd`, default on, disable with `--no-sync`/`-NoSync`)
   - `--sync-only`/`-SyncOnly`: bypasses download/stage/copy/redeploy and only calls desktop frontends' Rime sync; iOS-only frontends (no `sync_cmd`) cannot report sync-only complete; conflicts (`--init`/`--delete`/`--target`/`--no-download`/`--no-sync`, and `--cloud-sync` × `--no-sync`) are rejected before side effects
   - `--cloud-sync` (macOS only): order is pre-bridge → update/Rime sync → post-bridge; one bridge pair per invocation regardless of frontend count. Squirrel `--sync` is an async notification with no completion signal (upstream discards the result), so the chain honestly stops at "submitted" with exit code 75 and a manual `./cmd/sync-userdict.sh` post-bridge step. WeaselDeployer `/sync` blocks until the maintenance thread finishes, so `-SyncOnly` exit codes are completion results on Windows.
   - Exit codes: `0` success, `1` failure, `75` cloud chain pending manual post-bridge

### Userdict Cloud Sync Flow (Optional)

`cmd/sync-userdict.sh` (macOS only) uses Unison for the iCloud ↔ OneDrive bridge;
Windows has no cloud bridge: Weasel reads/writes its local OneDrive folder directly via the Rime `sync_dir` in its own installation.yaml, and `update.ps1 -CloudSync` is explicitly rejected.

```
Windows Rime → local OneDrive dir (installation.yaml sync_dir)
                        ⇕ same OneDrive account + same logical folder (eventual consistency)
macOS Rime → local OneDrive dir (sync_dir)
                        ⇕ Unison (cmd/sync-userdict.sh, macOS-only bridge)
                local iCloud dir
                        ⇕ iCloud client / iOS Rime sync
                   iOS Rime
```

**Configuration (`cmd/frontends.json`):**
```json
{"userdict_sync": {
  "icloud": "~/Library/Mobile Documents/com~apple~CloudDocs/RimeUserSync",
  "onedrive": {"darwin": "~/Library/CloudStorage/OneDrive-Personal/Apps/RimeSync"}
}}
```

Rime's own `installation.yaml/sync_dir` and this tool config are two different settings that must point at the same logical folders; desktop sync_dir uses absolute paths (Rime does not expand `~`). Full entry: `./cmd/update.sh --sync-only --cloud-sync` (pre-bridge → submit sync → exit 75 + manual post-bridge `./cmd/sync-userdict.sh`). `--dry-run` prints dirs/policy/steps only and never starts Unison (not an accurate cloud diff preview); it is not a pseudo-interactive unison session. Unison policy stays `-times -perms 0 -prefer newer`, ignoring `.DS_Store`/`*.tmp`; user archives are never migrated or cleaned by the tool.

**sync_dir structure** (distinguished by `installation_id`):
```
RimeUserSync/
├── Squirrel-CsHeng's-Macbook-M1-Max/
├── Weasel-CsHeng's-PC/
├── Hamster-xxx/
└── ...
```

**Dependency:** `unison` (macOS: `brew install unison`)

Migrating an existing Mac from an iCloud sync_dir to OneDrive is a documented manual sequence in README.md (backup installation.yaml + snapshots, export via `Squirrel --sync`, converge both trees with one bridge run, then edit only `sync_dir` keeping the original `installation_id`; never re-init or bulk-rewrite/delete either cloud dir).

### Git Workflow

- Upstream content downloadable/generatable via `update.sh`/`update.ps1`: not tracked
- Only track local layer not overwritten by update (patches/dictionaries) and scripts/configs
- `cmd/frontends.json`: not tracked (user-local config, copied from `.tmpl`)

## Architecture Notes

### Multi-Platform Strategy
- Single source of truth: root `*.custom.yaml` files
- Platform-specific overrides: `cmd/{platform}/*.custom.yaml`
- Build system: `cmd/update.sh` merges and stages configs per platform
- Deployment: rsync with platform-specific filters (`rsync_filter` in frontends.json; paths relative to `cmd/`)

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
- 用户词库：`custom_phrase_user.dict.yaml`（gitignored，缺失时真实运行的 `update.sh`/`update.ps1` 从 `.example` 生成；dry-run 只把示例放进 stage），
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

- `jq`: frontends.json parsing (bash entries; PowerShell uses native JSON, no jq)
- `rsync`: configuration synchronization (bash update flow; not needed for `--sync-only`)
- `curl` + `unzip` (bash) / native `Invoke-RestMethod` + `Expand-Archive` (pwsh): upstream download, checked only when downloading
- `unison`: macOS cloud bridge only (optional)
- `bash`: macOS/Linux; Git Bash optional on Windows
- Platform-specific:
  - macOS: Squirrel installed
  - Windows: Weasel + PowerShell 7 (yq/Git Bash/rsync/jq/curl/unzip NOT required)
  - iOS: Hamster app installed

## Validation

### Pre-Commit Checks
- Rime YAML syntax: `yq eval '.' <file>` (exit 0 = valid)
- frontends.json: `jq empty <file>` (exit 0 = valid)
- update.ps1 syntax: pwsh `[System.Management.Automation.Language.Parser]::ParseFile(...)` (no errors)
- Bash syntax: `bash -n cmd/*.sh`; lint: `shellcheck -S warning cmd/*.sh`
- Scenario tests: `bash cmd/tests/run-tests.sh` and `pwsh -NoProfile -File cmd/tests/run-tests.ps1`
  (macOS pwsh results do NOT count as Windows-native evidence; see cmd/tests/README.md)
- Path format (Windows bash entry): verify `/c/...` style in `cmd/frontends.json`
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
