# 工具脚本 (cmd/)

- `platforms.yaml`：平台配置（target_dir / filter / ui_layer）
- `platforms.sh`：薄封装（用 yq 读取 `platforms.yaml`，对外提供 bash 函数）
- `update.sh`：日常更新；使用 `--init` 参数可在更新前执行初始化（写入缺失的 installation.yaml 和 user.yaml）
  - 下载上游到 `build/upstream/`（只下载一次）
  - 把"上游 + 本地通用层 + UI 层"合并到 `build/stage/<platform>/`
  - 再用 rsync + per-platform filter 同步到目标目录（一次 rsync 完成写入）

约定：
- 同步与过滤统一用 rsync；不再使用 cp。
- 每个 UI/平台维护独立 `cmd/<ui>/rsync.filter`，用于精细控制"合并结果"如何写入目标目录。
- 默认使用 `--delete` 清理合并结果中不存在的文件；如需保留目标端多余文件，使用 `--no-delete`。
