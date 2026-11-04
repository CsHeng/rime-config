# rime-config

Rime 输入法配置仓库。追踪 **update 不会覆盖**的本地配置层，支持跨设备复用。

- 上游：`https://github.com/amzxyz/rime-wanxiang`
- 数据/语法模型：`https://github.com/amzxyz/rime-wanxiang-data`（原 `amzxyz/RIME-LMDG`，仓库改名）
- 前端配置：`cmd/frontends.json`（frontend = Rime 的 frontend/壳子；macOS/Windows 两入口共用单一 JSON 配置）

## 前置配置

**首次使用前必须创建配置文件：**

```bash
cp cmd/frontends.json.tmpl cmd/frontends.json
```

编辑 `cmd/frontends.json`，设置各前端的目标目录（`target_dir`）：

```json
{
  "frontends": {
    "squirrel": {
      "active": "auto",
      "target_dir": "~/Library/Rime"
    },
    "hamster3": {
      "active": true,
      "target_dir": "~/Library/Mobile Documents/.../rime-wanxiang"
    }
  }
}
```

**active 标志说明：**
- `"auto"` (默认)：系统检测到该平台时自动运行
- `true`：强制运行（无论系统检测，可多选）
- `false`：禁用

命令（`redeploy_cmd`/`sync_cmd`）是 `{"executable": ..., "args": [...]}` 对象，参数原样传给进程
（不做 shell 字符串解析）；配置内相对路径相对配置文件目录解释。从旧版 `frontends.yaml` 迁移的步骤
见 [cmd/README.md](cmd/README.md)。

## 快速开始（macOS）

```bash
# 首次使用（初始化 + 更新）
./cmd/update.sh --init

# 日常更新（自动处理所有 active frontends，默认含 redeploy + Rime 同步）
./cmd/update.sh

# 仅触发 Rime 用户词库同步（不下载/stage/复制/redeploy，离线可用）
./cmd/update.sh --sync-only
```

## Windows (Weasel) / PowerShell 7（推荐）

`cmd/update.ps1` 是 Windows 入口，**只需 PowerShell 7 + 已安装的小狼毫**，
不要求 yq、Git Bash、rsync、curl、jq、unzip（配置用原生 JSON 解析，文件操作/下载/解压均为 PowerShell 原生）。

```powershell
scoop install pwsh   # 或从 GitHub Releases 安装 PowerShell 7
```

配置（`cmd/frontends.json`，`target_dir` 推荐原生 `C:\...`，`/c/...` 也接受并自动转换）：

```json
{
  "frontends": {
    "weasel": {
      "active": true,
      "target_dir": "C:\\Users\\<User>\\AppData\\Roaming\\Rime",
      "ui_layer": "weasel",
      "rsync_filter": "weasel/update-rsync.filter",
      "bootstrap_filter": "weasel/bootstrap-rsync.filter",
      "redeploy_cmd": {"executable": "WeaselDeployer.exe", "args": ["/deploy"]},
      "sync_cmd":     {"executable": "WeaselDeployer.exe", "args": ["/sync"]}
    }
  }
}
```

运行：

```powershell
# 首次使用
pwsh cmd/update.ps1 -Init

# 日常更新
pwsh cmd/update.ps1

# 仅触发 Rime 用户词库同步（WeaselDeployer /sync 会等待同步完成，退出码即结果）
pwsh cmd/update.ps1 -SyncOnly

# 预览 + 调试
pwsh cmd/update.ps1 -DryRun
pwsh cmd/update.ps1 -DryRun -Delete
```

`-CloudSync` 会明确报错：iCloud ↔ OneDrive 桥只在 macOS（bash + Unison）运行；
Windows 的 Rime 通过自己 installation.yaml 的 `sync_dir` 直接读写本机 OneDrive 目录。

### Windows (Weasel) / Git Bash（备选）

仍可使用 `./cmd/update.sh`，但需要 `scoop install cwrsync jq unzip curl`（Git Bash 入口依赖
rsync/jq/unzip/curl），且 `target_dir` **只接受** `/c/...` 风格。

### 静默部署（Silent Deployment）

如需静默部署（无 UI 弹窗），把 `redeploy_cmd` 配成以 `powershell.exe` 为 executable 的命令对象：

```json
{
  "redeploy_cmd": {
    "executable": "powershell.exe",
    "args": ["-Command", "Start-Process -FilePath 'D:\\Applications\\Scoop\\apps\\weasel\\current\\WeaselDeployer.exe' -ArgumentList '/deploy' -WindowStyle Hidden"]
  }
}
```

**注意：** 需将 `WeaselDeployer.exe` 路径替换为实际安装位置；参数原样传递，不做二次 shell 解析。

## 常用命令

```bash
# 预览要删除的文件（清理废弃配置；dry-run 不写目标/不生成短语文件/不调用任何命令）
./cmd/update.sh --dry-run --delete

# 执行清理
./cmd/update.sh --delete

# 只更新不同步（不触发 Rime 用户词库同步）
./cmd/update.sh --no-sync

# 仅触发 Rime 同步（离线，不下载/stage/复制/redeploy）
./cmd/update.sh --sync-only

# 更新 + 完整云桥链路（前桥接 → 更新/同步 → 手动后桥接，见下节）
./cmd/update.sh --cloud-sync

# 使用指定配置（相对路径相对 cwd；.env 只从该配置目录加载）
./cmd/update.sh --config path/to/frontends.json
```

退出码：`0` 成功；`1` 失败（输出 frontend|stage|exit 汇总）；`75` 云桥链路停在「已提交」（见下节）。
`--sync-only` 不能与 `--init`/`--delete`/`--target`/`--no-download`/`--no-sync` 组合；
`--cloud-sync` 不能与 `--no-sync` 组合，且仅在 macOS 可用。

## 用户词库云同步

拓扑（每台设备保留唯一稳定的 `installation_id`，同步的是 `RimeUserSync/<installation_id>/*.userdb.txt`
等 Rime 快照，不碰运行中的 `*.userdb` 数据库）：

```
Windows Rime ── /sync ── 本机 OneDrive 目录（installation.yaml 的 sync_dir，无云桥）
                                  ⇅ 同一账号、同一逻辑 OneDrive 目录，OneDrive 客户端传输（最终一致）
macOS Rime    ── --sync ── 本机 OneDrive 目录（sync_dir）
                                  ⇅ Unison（cmd/sync-userdict.sh，macOS 本地桥接）
                            本机 iCloud 目录
                                  ⇅ iCloud 客户端 / iOS Rime 同步
                               iOS Rime
```

**两类设置必须对齐（不是同一份东西）：**

- 各设备 Rime 自己的 `installation.yaml/sync_dir`：桌面端指向**本机** OneDrive 目录（绝对路径，
  Rime 不展开 `~`），iOS 指向 iCloud；仓库模板 `cmd/<frontend>/installation.yaml` 仅在目标缺失时
  初始化，绝不覆盖已有 installation（重新初始化会重置 installation_id，禁止在真实安装上做）。
- 本工具的 `cmd/frontends.json` `userdict_sync`：只有 `icloud`（iCloud 目录）与
  `onedrive.darwin`（macOS 本机 OneDrive 目录），供 macOS 桥接脚本使用；Windows 不需要也不读取它。

**同一 OneDrive 账号、同一个逻辑文件夹**是硬前提；本机命令成功只代表本机步骤完成，远端设备
  要等 OneDrive/iCloud 客户端完成传输（最终一致性），iOS 端还需手动执行「同步/重新部署」。

**依赖：** `brew install unison`（仅 macOS 桥接需要；Windows 只需 pwsh + 小狼毫）

**使用（macOS）：**

```bash
# 完整链路：前桥接 → Rime 同步（提交）→ 【等 Squirrel 完成】→ 手动后桥接
./cmd/update.sh --sync-only --cloud-sync     # 停在已提交，退出码 75
./cmd/sync-userdict.sh                       # 待 Rime 同步完成后手动后桥接

# 日常更新需要桥接时
./cmd/update.sh --cloud-sync                 # 前桥接在前，更新/同步后同样停在手动后桥接

# 只看桥接计划（不启动 Unison，不是云端差异的精确预览）
./cmd/sync-userdict.sh --dry-run

# 详细输出 / 跳过大量删除确认
./cmd/sync-userdict.sh --verbose
./cmd/sync-userdict.sh --force
```

**为什么后桥接不自动执行：** Squirrel `--sync` 只投递异步通知后即退出，上游没有任何完成信号
（结果被丢弃、无事件/日志可观察），自动后桥接可能把旧快照推回云端。因此链路诚实停在「已提交」
（退出码 75）并提示手动步骤；WeaselDeployer `/sync` 会等待同步完成，Windows `-SyncOnly` 以
退出码作为结果。多前端更新时整次调用只执行一组前后桥接，不按前端重复。

**已有 Mac 从 iCloud sync_dir 迁到 OneDrive（人工步骤，按序执行）：**

1. 确认云端本地副本可用：iCloud 与 OneDrive 目录在本机都已下载完成（无云端占位文件）。
2. 预览桥接：`./cmd/sync-userdict.sh --dry-run`，确认两端目录正确。
3. 保全现状：备份 `~/Library/Rime/installation.yaml` 与两端 `RimeUserSync/` 快照（任一步失败
   用它们恢复；不倒灌旧 userdb、不删除任一云目录）。
4. 导出现状：在当前 iCloud sync_dir 配置下执行一次 `Squirrel --sync`，让最新词条进入快照。
5. 让两棵同步树收敛：用 `./cmd/sync-userdict.sh` 完成一次双向合并（此时两端都包含全部快照）。
6. 只改 `sync_dir`：编辑 `~/Library/Rime/installation.yaml`，把 `sync_dir` 改为本机 OneDrive 目录
   （如 `/Users/<you>/Library/CloudStorage/OneDrive-Personal/Apps/RimeSync`），**保留原 installation_id**，
   不重新 `--init`，不批量重写/删除任一云目录。
7. 验证：再执行一次 Rime 同步，确认 OneDrive 目录下出现本机 `installation_id` 的最新快照；
   之后按上面常规链路使用。

真实验收（Windows ↔ Mac ↔ iOS 各造一个可识别测试词，等客户端就绪后确认导入）需要真实设备与
明确授权后进行；脚本仓库不冒充已完成跨设备联通。

## 配置说明

### 自定义置顶短语

短语库通过“词库（dictionary）+ 编译入口”接入，而不是 `custom_phrase/user_dict`
（万象的 `custom_phrase` 组件为 `enable_user_dict: false`，该键会被 librime 完全忽略）。

```
custom_phrase_user.dict.yaml (仓库根，gitignored)
        │  deploy: update.sh / update.ps1 复制到各前端 target
        ▼
<target>/custom_phrase_user.dict.yaml
        │  重新部署（Squirrel --reload / WeaselDeployer /deploy）
        │  wanxiang_phrase.custom.yaml -> translator/dictionary: custom_phrase_user
        ▼
<target>/build/custom_phrase_user.table.bin + .reverse.bin + wanxiang_phrase.prism.bin
        │  runtime: wanxiang.custom.yaml -> custom_phrase/dictionary: custom_phrase_user
        ▼
wanxiang.custom_phrase Lua filter 把整编码候选提到首位（置顶）
```

文件行格式为 `<短语><TAB><编码><TAB><权重>`，编码可以是任意字母串（如 `gsdz`、`email`），
同一编码多行时权重大的排前面。文件位于各前端 Rime 用户目录：
- macOS (Squirrel): `~/Library/Rime/custom_phrase_user.dict.yaml`
- Windows (Weasel / Git Bash): `/c/Users/<User>/AppData/Roaming/Rime/custom_phrase_user.dict.yaml`
- iOS (Hamster3): `Documents/RimeUserData/<方案目录>/custom_phrase_user.dict.yaml`

文件缺失时 `update.sh` / `update.ps1` 会用 `custom_phrase_user.dict.yaml.example` 自动生成一份空模板。
该文件是短语库的**唯一来源**：上游 `custom_phrase.dict.yaml` 的内置示例不再参与（需要时把对应行抄进本文件即可）。
**编辑后必须重新部署**才会生效（部署时才会编译成 `build/custom_phrase_user.table.bin`）。

### iOS (Hamster3/元书) 三个目录与自造词（重要）

元书把 Rime 文件放在三处，并不实时同步，只在「重新部署」/「同步」时按规则流转：

| 位置 | 路径 | 说明 |
| --- | --- | --- |
| iCloud | `iCloud~com~ihsiao~apps~Hamster3/Documents/RimeUserData/rime-wanxiang` | 本仓库 hamster3 的 target（方案/patch 来源） |
| 应用 | app 沙盒内同构目录 | Rime 实际运行的 `user_data_dir`；`include_keyboard_rime_files.txt` 等规则文件也在此 |
| 键盘 | App Group 容器 | 真正保存自造词/词频（`*.userdb`）的地方 |

流转规则（重新部署/同步时）：`iCloud → 应用`（**覆盖式合并**，排除规则见 `应用/RimeSharedSupport/exclude_iCloud_rime_files.txt`）
→ 运行 RIME（部署或同步）→ `应用 → 键盘`（**整体回写，先删后拷**）。其中 `键盘 → 应用` 只复制匹配
`include_keyboard_rime_files.txt` 的文件，并且会先删除应用侧方案根目录下的 `*.userdb` 目录。

由此得到两条必须遵守的约束：

- `include_keyboard_rime_files.txt` **必须包含 `.*[.]userdb.*$`**（仓库在 `cmd/hamster3/include_keyboard_rime_files.txt` 维护）。
  缺了它：应用侧 userdb 被删除后不会从键盘拷回，回写时又把键盘覆盖掉 → **每次部署都会清空手机的自造词/词频**。
- **不要**写 `^.*[.]custom.*$` 这类规则：那会让键盘上的旧 `.custom.yaml` 覆盖 iCloud 上的新 patch，
  手机就永远拿不到仓库更新（表现为“自定义词/新配置不生效”）。
- 「RIME → 禁止复制键盘文件」需保持**关闭**，否则键盘侧一起被清空。

自造词跨设备合并：在手机上点「同步」，Mac 执行 `Squirrel --sync`（即 `cmd/update.sh` 默认的 `sync_cmd`），
Windows 执行 `WeaselDeployer /sync`；各设备的快照位于 `RimeUserSync/<installation_id>/<dict>.userdb.txt`，
由 `cmd/sync-userdict.sh`（Unison）负责 iCloud ↔ OneDrive 段。手机自造词丢失后，用已有快照再跑一次「同步」即可找回。

### 前端同步选项
- `--sync-only` / `-SyncOnly`：只调用桌面前端的 Rime 同步命令（离线，不进入更新流程）
- `--sync`：更新后触发 Rime 用户词库同步（默认开启）
- `--no-sync` / `-NoSync`：只更新配置文件，不触发用户词库同步（与 `--cloud-sync`/`-CloudSync` 互斥）

## 仓库追踪内容（git）

- `*.custom.yaml`：schema patch（通用层，含 `custom_phrase/dictionary` 与 `wanxiang_phrase*.custom.yaml` 编译入口）
- `custom_phrase_user.dict.yaml.example`：自定义短语模板（引导用户复制定制）
- `cmd/common/default.custom.yaml`：通用 UI patch
- `cmd/<ui>/*.custom.yaml`：UI 特定 patch
- `cmd/<ui>/{installation.yaml,user.yaml}`：初始化模板
- `cmd/<ui>/update-rsync.filter`：同步过滤规则
- `cmd/<ui>/bootstrap-rsync.filter`：初始化过滤规则

## 本地文件

- `custom_phrase_user.dict.yaml`：用户自定义置顶短语（gitignored；行格式 `<短语><TAB><编码><TAB><权重>`）

## 不追踪

- `cmd/frontends.json`：用户本地配置（从 frontends.json.tmpl 复制）
- 上游文件（通过 `update.sh` / `update.ps1` 可重建）
- `*.userdb/` 用户词库数据库
- `build/`（下载缓存、marker、stage 等）

## Stage 合并流程

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              build_stage_dir()                              │
│                        (per frontend: build/stage/<frontend>/)              │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  1. Base Layer: build/upstream/ (下载自 GitHub)                              │
│     - schema (rime-wanxiang-base.zip)                                        │
│     - dicts (base-dicts.zip)                                                │
│     - grammar (wanxiang-lts-zh-hans.gram)                                    │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ rsync -a
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  2. Local Layer: 仓库追踪文件（覆盖 Base）                                   │
│     - custom_phrase_user.dict.yaml (gitignored，缺失时用 .example 生成)      │
│     - *.custom.yaml (schema patches)                                         │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ rsync -a (覆盖)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  3. UI Overlay Layer: 前端特定配置（覆盖 Local）                            │
│     - cmd/common/default.custom.yaml                                         │
│     - cmd/<ui_layer>/*.custom.yaml                                          │
│       (例: cmd/squirrel/squirrel.custom.yaml)                                │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Result: build/stage/<frontend>/                                             │
│           (完整合并结果，准备 rsync 到 target)                                │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  rsync_stage_to_target()                                                    │
│  ──────────────────────────                                                  │
│  rsync -a --filter="merge cmd/<frontend>/update-rsync.filter"               │
│    build/stage/<frontend>/ -> <target_dir>/                                  │
│                                                                             │
│  过滤规则 (cmd/squirrel/update-rsync.filter):                                │
│    - user.yaml / - installation.yaml   # 保护用户状态                        │
│    - **.userdb/                        # 保护用户词库数据库整棵子树          │
│    - build/ / - lua/tips/ / - custom/  # 保护编译产物/运行时生成/上游文档    │
│    + *                                 # 其余同步（默认不 --delete）        │
│                                                                             │
│  Windows 入口 update.ps1 用自带过滤引擎执行同一份规则（目录感知遍历，        │
│  复制与删除共用判定，受保护内容在复制/显式删除/dry-run 下保持不变）         │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 脚本架构

详见 [cmd/README.md](cmd/README.md)

## For Agents

AI-specific instructions and context are in [AGENTS.md](./AGENTS.md).
