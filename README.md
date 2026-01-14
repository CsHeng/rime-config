# rime-config

Rime 输入法配置仓库。追踪 **update 不会覆盖**的本地配置层，支持跨设备复用。

- 上游：`https://github.com/amzxyz/rime_wanxiang`
- 平台配置：`cmd/platforms.yaml`（platform = Rime 的 UI 壳子）

## 快速开始

```bash
# 首次使用（初始化 + 更新）
./cmd/update.sh --init

# 日常更新
./cmd/update.sh
```

## 常用命令

```bash
# 预览要删除的文件（清理废弃配置）
./cmd/update.sh --dry-run --delete

# 执行清理
./cmd/update.sh --delete

# 只更新不同步
./cmd/update.sh --no-sync

# 指定平台
./cmd/update.sh --platform weasel
```

## 仓库追踪内容（git）

- `*.custom.yaml`：schema patch（通用层）
- `custom_phrase_user.txt`：各 UI 壳通用置顶词库
- `cmd/common/default.custom.yaml`：通用 UI patch
- `cmd/<ui>/*.custom.yaml`：UI 特定 patch
- `cmd/<ui>/{installation.yaml,user.yaml}`：初始化模板
- `cmd/<ui>/update-rsync.filter`：同步过滤规则
- `cmd/<ui>/bootstrap-rsync.filter`：初始化过滤规则

## 不追踪

- 上游文件（通过 `update.sh` 可重建）
- `*.userdb/` 用户词库数据库
- `build/`（下载缓存、marker、stage 等）

## 脚本架构

详见 [cmd/README.md](cmd/README.md)
