<INSTRUCTIONS>
# Repository Intent (rime-config)

仓库追踪不会被上游 update 覆盖的本地层，支持跨设备复用。上游内容通过脚本可重建。

## Definitions

- 自定义置顶短语：默认使用 `custom_phrase_user.txt`（通过 `wanxiang*.custom.yaml` 的 `custom_phrase/user_dict` 统一指向）

- **platform**：Rime 的 UI 壳子（`squirrel`=macOS / `weasel`=Windows / `hamster`、`hamster3`=iOS app）。

## Required Files (source-of-truth)

- 平台配置（mapping 真源）：`cmd/platforms.yaml`
- YAML 读取薄封装：`cmd/platforms.sh`（内部用 `yq` 读取 YAML，提供 bash 函数给脚本调用）
- 初始化脚本：`cmd/init.sh`
- 日常更新脚本：`cmd/update.sh`
- per-platform rsync filter：`cmd/<platform>/update-rsync.filter` (update) / `bootstrap-rsync.filter` (init)

## Flow: init (optional)

`cmd/update.sh --init` (internally calls `rsync_bootstrap_templates`) 只负责把 `cmd/<platform>/` 下的模板文件初始化到 target：
- 过滤规则：`cmd/<platform>/bootstrap-rsync.filter`
- 统一用 `rsync`，且仅写入缺失文件（`--ignore-existing`）

## Flow: update (daily)

`cmd/update.sh` 的核心约束：

1) **上游资源只下载一次**，输出到 repo 内的缓存目录：
- `build/cache/`：下载缓存
- `build/markers/`：版本 marker
- `build/upstream/`：上游解包后的目录（rsync 的 upstream 源）

2) 对每个 platform，生成一份可重建的“合并结果”目录：
- `build/stage/<platform>/` = upstream + 本地通用层 +（可选）UI 层
- 该目录可随时删除并通过流程重新生成

3) **platform 资源 + 下载的资源** 必须一起经过 per-platform filter，通过一次 `rsync` 写入 target：
- `rsync build/stage/<platform>/ -> <target>/` + `--filter="merge cmd/<platform>/update-rsync.filter"`
- 默认**不**使用 `--delete`（需要清理时手动 `--delete`，建议先用 `--dry-run --delete` 预览）

4) **Post-update Hooks**：
- 根据 `cmd/platforms.yaml` 配置自动执行 `redeploy_cmd`（默认开启，可用 `--no-redeploy` 关闭）
- 根据 `cmd/platforms.yaml` 配置自动执行 `sync_cmd`（默认开启，可用 `--no-sync` 关闭）

## Git Tracking Policy

- 能通过 `update.sh` 下载/生成的上游内容：不追踪
- 只追踪 update 不会覆盖的本地层（patch/词库）与脚本/配置

</INSTRUCTIONS>
