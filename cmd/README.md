# 工具脚本 (cmd/)

## 目录结构

```
cmd/
├── frontends.yaml          # 前端配置
├── frontends.sh            # YAML 读取薄封装（bash 函数）
├── update.sh               # 日常更新 + 可选初始化
├── common/                 # 通用层配置
│   └── default.custom.yaml
└── <ui>/                   # Frontend 特定配置
    ├── *.custom.yaml       # UI patch
    ├── installation.yaml   # 初始化模板
    ├── user.yaml           # 初始化模板
    ├── update-rsync.filter # 更新过滤规则
    └── bootstrap-rsync.filter # 初始化过滤规则
```

## 核心脚本

### frontends.sh
用 `yq` 读取 `frontends.yaml`，提供以下 bash 函数：
- `frontend_resolve_auto`：根据 OS 自动检测 frontend
- `frontend_ui_layer`：获取 UI 层配置
- `frontend_rsync_filter_file`：获取 rsync filter 路径
- `frontend_bootstrap_filter_file`：获取 bootstrap filter 路径
- `frontend_target_dir`：获取目标目录
- `frontend_redeploy_cmd`：获取重新部署命令
- `frontend_sync_cmd`：获取 Rime 用户词库同步命令

### update.sh
**流程：**
```
1. 下载 upstream → build/upstream/
2. 合并 upstream + 本地层 → build/stage/<frontend>/
3. rsync + filter → target/
4. 触发 redeploy/sync（可选）
```

**约定：**
- 统一使用 rsync，不用 cp
- 每个 frontend 维护独立的 filter 文件
- 默认不使用 `--delete`，需手动启用

## Filter 规则

### update-rsync.filter（日常更新）
保护内容：
- `user.yaml`, `installation.yaml`（用户状态）
- `**.userdb/`（用户数据库）
- `build/`（编译产物）
- `lua/tips/`（运行时生成）

### bootstrap-rsync.filter（初始化）
- 仅写入 `installation.yaml`, `user.yaml`
- 使用 `--ignore-existing` 不覆盖已存在文件

## 前端配置示例

```yaml
frontends:
  squirrel:
    target_dir: ~/Library/Rime
    ui_layer: squirrel
    rsync_filter: cmd/squirrel/update-rsync.filter
    bootstrap_filter: cmd/squirrel/bootstrap-rsync.filter
    redeploy_cmd: '"/Library/.../Squirrel" --reload'
    sync_cmd: '"/Library/.../Squirrel" --sync'
```
