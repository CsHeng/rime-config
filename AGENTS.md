
# Repository Intent (rime-config)

仓库追踪不会被上游 update 覆盖的本地层，支持跨设备复用。上游内容通过脚本可重建。

## Definitions

- 自定义置顶短语：用户在本地创建 `custom_phrase_user.txt`（通过 `wanxiang*.custom.yaml` 的 `custom_phrase/user_dict` 统一指向，路径需根据用户 Rime 用户目录调整）

- **frontend**：Rime 的 UI 壳子（`squirrel`=macOS / `weasel`=Windows / `hamster`、`hamster3`=iOS app）。

## Required Files

- `cmd/frontends.yaml.tmpl`：前端配置模板
- `cmd/frontends.sh`：YAML 读取薄封装（内部用 `yq` 读取 YAML，提供 bash 函数给脚本调用）
- `cmd/update.sh`：日常更新脚本
- `cmd/sync-userdict.sh`：用户词库云同步脚本（Unison 双向同步 iCloud ↔ OneDrive）
- per-frontend rsync filter：`cmd/<frontend>/update-rsync.filter` (update) / `bootstrap-rsync.filter` (init)

## Setup: 首次配置

**用户必须创建本地配置文件：**

```bash
cp cmd/frontends.yaml.tmpl cmd/frontends.yaml
# 编辑 cmd/frontends.yaml 设置 target_dir 和 active 标志
```

`cmd/frontends.yaml` 不追踪，用户可根据本地需求修改。

## Flow: init (optional)

`cmd/update.sh --init` (internally calls `rsync_bootstrap_templates`) 只负责把 `cmd/<frontend>/` 下的模板文件初始化到 target：
- 过滤规则：`cmd/<frontend>/bootstrap-rsync.filter`
- 统一用 `rsync`，且仅写入缺失文件（`--ignore-existing`）

## Flow: update (daily)

`cmd/update.sh` 的核心约束：

1) **上游资源只下载一次**，输出到 repo 内的缓存目录：
- `build/cache/`：下载缓存
- `build/markers/`：版本 marker
- `build/upstream/`：上游解包后的目录（rsync 的 upstream 源）

2) 对每个 active frontend，生成一份可重建的"合并结果"目录：
- `build/stage/<frontend>/` = upstream + 本地通用层 +（可选）UI 层
- 该目录可随时删除并通过流程重新生成

**Frontend 激活机制**（在 `cmd/frontends.yaml` 中配置）：
- `active: auto` (默认)：系统检测到该平台时自动运行
- `active: true`：强制运行，支持同时激活多个 frontend
- `active: false`：禁用

示例：在 macOS 上同时部署到 squirrel 和 hamster3：
```yaml
frontends:
  squirrel:
    active: auto  # darwin 自动检测
  hamster3:
    active: true  # 强制启用
```

3) **frontend 资源 + 下载的资源** 必须一起经过 per-frontend filter，通过一次 `rsync` 写入 target：
- `rsync build/stage/<frontend>/ -> <target>/` + `--filter="merge cmd/<frontend>/update-rsync.filter"`
- 默认**不**使用 `--delete`（需要清理时手动 `--delete`，建议先用 `--dry-run --delete` 预览）

4) **Post-update Hooks**：
- 根据 `cmd/frontends.yaml` 配置自动执行 `redeploy_cmd`（默认开启，可用 `--no-redeploy` 关闭）
- 根据 `cmd/frontends.yaml` 配置自动执行 Rime 用户词库同步（`sync_cmd`，默认开启，可用 `--no-sync` 关闭）
- 可选：`--cloud-sync` 触发云端用户词库同步（iCloud ↔ OneDrive）

## Flow: userdict cloud sync (optional)

`cmd/sync-userdict.sh` 使用 Unison 实现 iCloud ↔ OneDrive 双向同步：

```
Windows (weasel) ←→ OneDrive ←→ macOS (squirrel) ←→ iCloud ←→ iOS (hamster/hamster3)
```

**配置（`cmd/frontends.yaml`）：**

```yaml
userdict_sync:
  icloud: ~/Library/Mobile Documents/com~apple~CloudDocs/RimeUserSync
  onedrive:
    darwin: ~/Library/CloudStorage/OneDrive-Personal/Apps/RimeSync
    windows: /c/Users/<User>/OneDrive/Apps/RimeSync
```

**sync_dir 结构**（以 `installation_id` 区分设备）：

```
RimeUserSync/
├── Squirrel-CsHeng's-Macbook-M1-Max/
├── Weasel-CsHeng's-PC/
├── Hamster-xxx/
└── ...
```

**依赖：** `unison`（macOS: `brew install unison`）

## Git Tracking Policy

- 能通过 `update.sh` 下载/生成的上游内容：不追踪
- 只追踪 update 不会覆盖的本地层（patch/词库）与脚本/配置
- `cmd/frontends.yaml`：不追踪（用户本地配置，从 `.tmpl` 复制）


