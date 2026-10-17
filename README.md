# rime-config

Rime 输入法配置仓库。追踪 **update 不会覆盖**的本地配置层，支持跨设备复用。

- 上游：`https://github.com/amzxyz/rime-wanxiang`
- 数据/语法模型：`https://github.com/amzxyz/rime-wanxiang-data`（原 `amzxyz/RIME-LMDG`，仓库改名）
- 前端配置：`cmd/frontends.yaml`（frontend = Rime 的 frontend/壳子）

## 前置配置

**首次使用前必须创建配置文件：**

```bash
cp cmd/frontends.yaml.tmpl cmd/frontends.yaml
```

编辑 `cmd/frontends.yaml`，设置各前端的目标目录（`target_dir`）：

```yaml
frontends:
  squirrel:
    active: auto       # macOS 上自动运行
    target_dir: ~/Library/Rime
  hamster3:
    active: true       # 强制运行（可与 squirrel 同时使用）
    target_dir: ~/Library/Mobile Documents/.../rime-wanxiang
```

**active 标志说明：**
- `auto` (默认)：系统检测到该平台时自动运行
- `true`：强制运行（无论系统检测，可多选）
- `false`：禁用

## 快速开始

```bash
# 首次使用（初始化 + 更新）
./cmd/update.sh --init

# 日常更新（自动处理所有 active frontends）
./cmd/update.sh
```

## Windows (Weasel) / Git Bash + Scoop

依赖（Scoop）：

```bash
scoop install cwrsync yq jq unzip curl
```

配置（`cmd/frontends.yaml`，Windows 下 `target_dir` **只接受** Git Bash 路径风格 `/c/...`）：

```yaml
frontends:
  weasel:
    active: auto
    # Weasel 默认目录：%APPDATA%\\Rime
    target_dir: /c/Users/<User>/AppData/Roaming/Rime
```

运行建议（先 dry-run 看日志）：

```bash
./cmd/update.sh --init --debug
./cmd/update.sh --dry-run --debug
./cmd/update.sh --debug
```

### Windows (Weasel) / PowerShell 7（推荐）

`update.ps1` 是 `update.sh` 的 PowerShell 7 移植版，**无需 rsync**，用原生文件操作替代。

依赖：PowerShell 7+ 和 yq

```powershell
scoop install pwsh yq
```

配置（`cmd/frontends.yaml`，`target_dir` 使用 `/c/...` 或 `C:\...` 均可）：

```yaml
frontends:
  weasel:
    active: auto
    target_dir: /c/Users/<User>/.config/rime
```

运行：

```powershell
# 首次使用
pwsh cmd/update.ps1 -Init

# 日常更新
pwsh cmd/update.ps1

# 预览 + 调试
pwsh cmd/update.ps1 -DryRun
pwsh cmd/update.ps1 -DryRun -Delete
```

### 静默部署（Silent Deployment）

如需静默部署（无 UI 弹窗），可在 `cmd/frontends.yaml` 中配置 `redeploy_cmd`：

```yaml
frontends:
  weasel:
    # 静默部署示例（需根据实际安装路径调整 WeaselDeployer.exe 位置）
    redeploy_cmd: 'powershell.exe -Command "Start-Process -FilePath \"D:\\Applications\\Scoop\\apps\\weasel\\current\\WeaselDeployer.exe\" -ArgumentList \"/deploy\" -WindowStyle Hidden"'
```

**注意：** 需将 `WeaselDeployer.exe` 路径替换为实际安装位置。

## 常用命令

```bash
# 预览要删除的文件（清理废弃配置）
./cmd/update.sh --dry-run --delete

# 执行清理
./cmd/update.sh --delete

# 只更新不同步（不触发 Rime 用户词库同步）
./cmd/update.sh --no-sync

# 更新后同步用户词库到云端
./cmd/update.sh --cloud-sync
```

## 用户词库云同步

macOS 作为中转站，双向同步 iCloud ↔ OneDrive，实现跨平台用户词库共享：

```
Windows (weasel) ←→ OneDrive ←→ macOS (squirrel) ←→ iCloud ←→ iOS (hamster/hamster3)
```

**依赖：** `brew install unison`

**配置（`cmd/frontends.yaml`）：**

```yaml
userdict_sync:
  icloud: ~/Library/Mobile Documents/com~apple~CloudDocs/RimeUserSync
  onedrive:
    darwin: ~/Library/CloudStorage/OneDrive-Personal/Apps/RimeSync
    windows: /c/Users/<User>/OneDrive/Apps/RimeSync
```

**使用：**

```bash
# 预览同步内容
./cmd/sync-userdict.sh --dry-run

# 执行双向同步
./cmd/sync-userdict.sh

# 详细输出
./cmd/sync-userdict.sh --verbose
```

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
- `--sync`：触发 Rime 用户词库同步（默认开启）
- `--no-sync`：只更新配置文件，不触发用户词库同步

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

- `cmd/frontends.yaml`：用户本地配置（从 frontends.yaml.tmpl 复制）
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
│  过滤规则示例 (cmd/squirrel/update-rsync.filter):                            │
│    + *.custom.yaml  # 只同步自定义 schema patch                              │
│    + *.txt         # 自定义词组文件                                         │
│    - *             # 排除其他（避免覆盖用户自定义）                           │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 脚本架构

详见 [cmd/README.md](cmd/README.md)

## For Agents

AI-specific instructions and context are in [AGENTS.md](./AGENTS.md).
