# 工具脚本 (cmd/)

## 目录结构

```
cmd/
├── frontends.json.tmpl    # 前端配置模板（复制为 frontends.json）
├── frontends.json         # 用户本地配置（从模板复制，不入 Git）
├── frontends.sh           # frontends.json 读取薄封装（bash 函数，依赖 jq）
├── update.sh              # 日常更新 + Rime 同步 + 云桥（macOS/Linux/Git Bash）
├── update.ps1             # 日常更新 + Rime 同步（Windows PowerShell 7，无 yq/rsync 依赖）
├── sync-userdict.sh       # 用户词库云桥（macOS，Unison，iCloud ↔ OneDrive）
├── common/                # 通用层配置
│   └── default.custom.yaml
├── tests/                 # 场景测试（见 tests/README.md）
└── <ui>/                  # Frontend 特定配置
    ├── *.custom.yaml       # UI patch
    ├── installation.yaml   # 初始化模板（仅缺失时写入）
    ├── user.yaml           # 初始化模板
    ├── update-rsync.filter # 更新过滤规则
    └── bootstrap-rsync.filter # 初始化过滤规则
```

## 配置：cmd/frontends.json

单一配置真源，Windows 与 macOS 两个入口共用（PowerShell 原生解析，Bash 用 jq）：

```json
{
  "auto": { "darwin": "squirrel", "windows": "weasel" },
  "frontends": {
    "squirrel": {
      "active": "auto",
      "target_dir": "~/Library/Rime",
      "ui_layer": "squirrel",
      "rsync_filter": "squirrel/update-rsync.filter",
      "bootstrap_filter": "squirrel/bootstrap-rsync.filter",
      "redeploy_cmd": { "executable": "/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel", "args": ["--reload"] },
      "sync_cmd":     { "executable": "/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel", "args": ["--sync"] }
    }
  },
  "userdict_sync": {
    "icloud": "~/Library/Mobile Documents/com~apple~CloudDocs/RimeUserSync",
    "onedrive": { "darwin": "~/Library/CloudStorage/OneDrive-Personal/Apps/RimeSync" }
  }
}
```

- `active`: `"auto"`（按平台自动检测）/ `true`（强制启用，可多个）/ `false`（禁用）。
- 相对路径（`rsync_filter`、`*_cmd.executable` 等）相对配置文件目录解释；`target_dir` 与云目录建议
  绝对路径或 `~/`。
- `redeploy_cmd` / `sync_cmd` 是 `{executable, args}` 对象：参数原样传给进程（不做 shell 字符串
  解析，不经过 `sh -c` / `Invoke-Expression`），退出码会被检查并计入结果。
- 入口支持 `--config <file>` / `-Config <file>` 显式指定配置（相对路径相对调用者 cwd）；
  `.env`（如 `GITHUB_TOKEN`）只从所选配置目录加载。

**从旧版 frontends.yaml 迁移（一次性，人工执行）**：

1. `cp cmd/frontends.json.tmpl cmd/frontends.json`，按旧 `frontends.yaml` 逐项核对：
   `auto`、各前端 `active`/`target_dir`/`ui_layer`、云目录。
2. filter 路径从 `cmd/squirrel/update-rsync.filter` 改为相对 `cmd/` 的 `squirrel/update-rsync.filter`。
3. `redeploy_cmd`/`sync_cmd` 不能机械转换：把旧引号字符串拆成 `executable` + `args`
   （如 `'"WeaselDeployer.exe" /sync'` → `{"executable": "WeaselDeployer.exe", "args": ["/sync"]}`）。
4. Windows 端 `userdict_sync.onedrive.windows` 不再需要（Windows 没有云桥，Rime 的 sync_dir
   在小狼毫自己的 installation.yaml 里）。
5. 核对无误后再使用新入口；旧 `frontends.yaml` 留在原地作人工恢复输入，新入口不读它。

## frontends.sh

用 `jq` 读取 `frontends.json`（`FRONTENDS_CONFIG` 可覆盖路径），提供 bash 函数：
`frontends_validate`、`frontend_active_list`、`frontend_resolve_auto`、`frontend_ui_layer`、
`frontend_rsync_filter_file`、`frontend_bootstrap_filter_file`、`frontend_target_dir`、
`frontend_redeploy_cmd` / `frontend_sync_cmd`（以 NUL 分隔流输出 executable 与各参数，空参数/内嵌换行原样保留）、
`userdict_icloud_path` / `userdict_onedrive_path`。结构错误（坏 JSON、非法 `active`、命令对象形状
不对）会在副作用前给出带字段名的错误。

## update.sh（macOS/Linux/Git Bash）

```
1. 读取 frontends.json -> active 前端
2. [--cloud-sync] 前桥接（Unison）
3. 下载上游（可 --no-download 跳过）
4. 对每个 active frontend: 合并 upstream + 本地层 -> build/stage/<frontend>/
   rsync + filter -> target/；触发 redeploy/sync（可关）
5. [--cloud-sync] 后桥接：不自动执行（见下）
```

- `--sync-only`：跳过下载/stage/复制/redeploy，只调用桌面前端的 Rime 同步命令；
  全部 active 前端都没有 `sync_cmd` 时退出非零（明确未完成）。
- `--cloud-sync`（仅 macOS）：链路为 前桥接 → Rime 同步 → 后桥接。Squirrel `--sync` 是异步通知，
  上游无完成信号，因此链路停在「已提交」，**退出码 75**，并提示手动执行 `./cmd/sync-userdict.sh`
  完成后桥接；不假装闭环。前桥接失败不继续同步；Rime 失败不报整次成功。
- 冲突拒绝（副作用前）：`--sync-only` × {`--init`,`--delete`,`--target`,`--no-download`,`--no-sync`}、
  `--cloud-sync` × `--no-sync`。
- 目标校验（写入前）：多前端 + `--target` 拒绝；非 dry-run `--target` 必须同时
  `--no-redeploy --no-sync`；stage/模板/upstream 与目标重叠拒绝；多前端同目标拒绝。
- dry-run 不写目标、不生成 `custom_phrase_user.dict.yaml`（示例只进 stage）、不调用任何命令。
- 退出码：`0` 成功；`1` 失败（hook 失败会输出 frontend|stage|exit 汇总）；`75` 云桥链路停在已提交。

## update.ps1（Windows PowerShell 7）

`update.sh` 的 Windows 对应入口，**只需 PowerShell 7 + 小狼毫**（无 yq/rsync/curl/jq/unzip/Git Bash）：
配置用 `ConvertFrom-Json` 一次读取校验；下载用 `Invoke-RestMethod`/`Invoke-WebRequest`；
解压用 `Expand-Archive`；文件分发用自带过滤引擎（直接解析 `cmd/<frontend>/update-rsync.filter`，
目录感知遍历，复制与删除共用同一套规则，不支持的规则报错而不是静默忽略）。

```powershell
pwsh cmd/update.ps1 -Init            # 首次（只补缺失模板）
pwsh cmd/update.ps1                  # 日常更新（默认含 redeploy + Rime 同步）
pwsh cmd/update.ps1 -SyncOnly        # 仅调用 WeaselDeployer /sync（等待完成，检查退出码）
pwsh cmd/update.ps1 -DryRun -Delete  # 预览 + 显式清理
```

- `-CloudSync` 明确拒绝：iCloud ↔ OneDrive 桥只在 macOS 的 `sync-userdict.sh`（bash + Unison）运行；
  Windows 的 Rime 直接同步到本机 OneDrive 目录（sync_dir 在小狼毫 installation.yaml）。
- WeaselDeployer `/sync` 会等待同步完成（上游 `Configurator.cpp` 在 `join_maintenance_thread()`
  之后才退出），因此 `-SyncOnly` 以进程退出码作为结果；`/deploy`、`--reload` 等仍是尽力触发。
- Windows `target_dir` 推荐原生 `C:\...`（`/c/...` 也接受并自动转换）。

## sync-userdict.sh（macOS 云桥）

Unison 双向同步 `userdict_sync.icloud` ↔ `userdict_sync.onedrive.darwin`（同一对目录、同一份
Unison 归档状态；策略保持 `-times -perms 0 -prefer newer`，忽略 `.DS_Store`/`*.tmp`）。

- `--dry-run` 只输出目录、策略与待执行命令，**不启动 Unison**，也不是云端差异的精确预览。
- 失败返回非零并给出目录与退出码。
- 作为 `update.sh --cloud-sync` 的前桥接被调用；后桥接因 Squirrel 无完成信号需手动执行。

## Filter 规则

### update-rsync.filter（日常更新）
保护内容（bash 与 pwsh 共用同一份规则文件）：
- `user.yaml`, `installation.yaml`（用户状态）
- `**.userdb/`（用户数据库，整棵子树）
- `build/`（编译产物）、`lua/tips/`（运行时生成）
- `custom/`（上游文档）、其他前端 UI yaml

### bootstrap-rsync.filter（初始化）
- 仅写入 `installation.yaml`, `user.yaml`
- 只补缺失文件（不覆盖已存在）

### PowerShell 引擎支持的规则形态
`+ name` / `- name`（精确文件名，可加引号）、`- dir/`、`- path/`（锚定目录）、`- dir/**`、
`- **.suffix/`、`+ *` / `- *`。其他通配符写法会报错（避免与 rsync 语义不一致的静默行为）。
