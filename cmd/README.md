# 工具脚本 (cmd/)

## 目录结构

```
cmd/
├── frontends.yaml.tmpl    # 前端配置模板
├── frontends.yaml          # 用户本地配置（从模板复制）
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
- `frontend_active_list`：获取所有启用的 frontend 列表

### update.sh
**流程：**
```
1. 下载 upstream → build/upstream/
2. 对每个 active frontend:
   - 合并 upstream + 本地层 → build/stage/<frontend>/
   - rsync + filter → target/
   - 触发 redeploy/sync（可选）
```

**Frontend 激活机制：**
- `active: auto` (默认)：系统检测到该平台时自动运行
- `active: true`：强制运行，支持同时激活多个 frontend
- `active: false`：禁用

**示例：macOS 上同时运行 squirrel 和 hamster3**
```yaml
frontends:
  squirrel:
    active: auto  # darwin 自动检测
  hamster3:
    active: true  # 强制启用
```

**约定：**
- 统一使用 rsync，不用 cp
- 每个 frontend 维护独立的 filter 文件
- 默认不使用 `--delete`，需手动启用

Windows 说明（Weasel / Git Bash + Scoop）：
- 建议用 Scoop 安装依赖：`scoop install cwrsync yq jq unzip curl`
- `cmd/frontends.yaml` 中 Windows 的 `target_dir` 只接受 `/c/...` 风格（避免 `C:\...` 被 rsync 解析为 remote 或触发 argv 路径转换问题）

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
    active: auto
    target_dir: ~/Library/Rime
    ui_layer: squirrel
    rsync_filter: cmd/squirrel/update-rsync.filter
    bootstrap_filter: cmd/squirrel/bootstrap-rsync.filter
    redeploy_cmd: '"/Library/.../Squirrel" --reload'
    sync_cmd: '"/Library/.../Squirrel" --sync'
```
