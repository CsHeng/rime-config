# rime-config

精简追踪：只保留 **update 不会覆盖**、且需要跨设备复用的本地配置层。

- 上游：`https://github.com/amzxyz/rime_wanxiang`
- 平台配置：`cmd/platforms.yaml`（platform = Rime 的 UI 壳子；其中 `hamster`/`hamster3` 是 iOS app）

## 用法

- 首次初始化（可选）：`./cmd/init.sh --platform <auto|squirrel|weasel|hamster|hamster3>`
- 日常更新：`./cmd/update.sh --platform <auto|squirrel|weasel|hamster|hamster3>`（默认 `auto`）

说明：
- 自定义置顶短语使用 `custom_phrase_user.txt`（由 `wanxiang.custom.yaml` 配置 `custom_phrase/user_dict` 指向）
- `--target <dir>` 仅用于临时测试覆盖；正常由 `cmd/platforms.yaml` 推导目标目录。

## 仓库追踪内容（git）

- `*.custom.yaml`：schema patch（通用层）
- `custom_phrase_user.txt`：各 UI 壳通用置顶词库
- `cmd/common/default.custom.yaml`：通用 UI patch（可选写入目标根目录）
- `cmd/<ui>/*.custom.yaml`：UI patch（按平台选择性写入目标根目录）
- `cmd/<ui>/{installation.yaml,user.yaml}`：每个壳子的模板（init 仅在目标缺失时写入）
- `cmd/<ui>/rsync.filter`：合并后（upstream+overlays）-> target 的同步过滤规则

## 不追踪

- 所有可通过 `update.sh` 下载/生成的上游文件
- `*.userdb/` 等用户词库数据库（建议用 Rime user sync / sync_dir 在 git 之外同步）
- `build/`（下载缓存、marker、stage 等，可随时重建）
