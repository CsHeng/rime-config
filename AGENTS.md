<INSTRUCTIONS>
# Repository Intent (rime-config)

目标：把仓库追踪内容收敛为“不会被上游 update 覆盖、且需要跨设备复用”的本地层；上游内容一律通过脚本可重建。

## Definitions

- **platform**：Rime 的 UI 壳子（`squirrel` / `weasel` / `hamster` / `hamster3`）。
- 不使用 `ios` 这种聚合“系统 platform”。

## Required Files (source-of-truth)

- 平台配置（mapping 真源）：`cmd/platforms.yaml`
- YAML 读取薄封装：`cmd/platforms.sh`（内部用 `yq` 读取 YAML，提供 bash 函数给脚本调用）
- 初始化脚本：`cmd/init.sh`
- 日常更新脚本：`cmd/update.sh`
- per-platform rsync filter：`cmd/<platform>/rsync.filter`

## Flow: init (optional)

`cmd/init.sh` 只负责把 `cmd/<platform>/{installation.yaml,user.yaml}` 初始化到 target 根目录：
- 统一用 `rsync`，且仅写入缺失文件（`--ignore-existing`）
- 不下载上游、不写入本地层

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
- `rsync build/stage/<platform>/ -> <target>/` + `--filter="merge cmd/<platform>/rsync.filter"`
- 默认开启 `--delete`（可用 `--no-delete` 或 `RIME_RSYNC_DELETE=0` 关闭）

## Git Tracking Policy

- 能通过 `update.sh` 下载/生成的上游内容：不追踪
- 只追踪 update 不会覆盖的本地层（patch/词库）与脚本/配置

</INSTRUCTIONS>
