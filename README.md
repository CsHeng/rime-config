# rime-config

Rime 输入法配置仓库。追踪 **update 不会覆盖**的本地配置层，支持跨设备复用。

- 上游：`https://github.com/amzxyz/rime_wanxiang`
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

## 常用命令

```bash
# 预览要删除的文件（清理废弃配置）
./cmd/update.sh --dry-run --delete

# 执行清理
./cmd/update.sh --delete

# 只更新不同步（不触发 Rime 用户词库同步）
./cmd/update.sh --no-sync
```

## 配置说明

### 自定义词组路径
`custom_phrase_user.txt` 的路径在 `wanxiang*.custom.yaml` 中通过 `custom_phrase/user_dict` 指定。**用户需根据本地 Rime 用户目录调整路径**，例如：
- macOS (Squirrel): `~/Library/Rime/custom_phrase_user.txt`
- Windows (Weasel): `%APPDATA%\Rime\custom_phrase_user.txt`
- iOS (Hamster): 通过 app 内部文件管理访问

### 前端同步选项
- `--sync`：触发 Rime 用户词库同步（默认开启）
- `--no-sync`：只更新配置文件，不触发用户词库同步

## 仓库追踪内容（git）

- `*.custom.yaml`：schema patch（通用层）
- `custom_phrase.txt`：自定义词组示例（引导用户复制定制）
- `cmd/common/default.custom.yaml`：通用 UI patch
- `cmd/<ui>/*.custom.yaml`：UI 特定 patch
- `cmd/<ui>/{installation.yaml,user.yaml}`：初始化模板
- `cmd/<ui>/update-rsync.filter`：同步过滤规则
- `cmd/<ui>/bootstrap-rsync.filter`：初始化过滤规则

## 本地文件

- `custom_phrase_user.txt`：用户自定义词组（基于 custom_phrase.txt 复制定制）

## 不追踪

- `cmd/frontends.yaml`：用户本地配置（从 frontends.yaml.tmpl 复制）
- 上游文件（通过 `update.sh` 可重建）
- `*.userdb/` 用户词库数据库
- `build/`（下载缓存、marker、stage 等）

## 脚本架构

详见 [cmd/README.md](cmd/README.md)
