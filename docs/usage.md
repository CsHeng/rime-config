# 使用参考

本文是配置与日常使用的参考，设计理由见 [架构](architecture.md)。选项、选项组合规则和计划行的含义以 `rime-config -h` 为准，mise 任务以 `mise tasks` 为准。

## 运行方式

mise 任务运行 `dist/<os>-<arch>/` 下的二进制，并先切换到项目根目录；额外参数放在 `--` 之后，例如 `mise run update -- --delete`。改代码后先运行 `mise run package`。

不用 mise 时，把 `dist/<platform>/` 下的压缩包解压到任意目录，直接运行 `./rime-config`，默认读取 `<可执行文件目录>/config/frontends.json`。

Windows 上运行 mise 任务需要 Git Bash。Weasel 的部署结果无法确认，工具会失败关闭，所以日常用 `mise run update -- --no-redeploy`，然后在托盘里手动部署。

## 配置文件

`config/frontends.json` 由 `--setup` 生成，不进 git；`config/frontends.json.example` 是脱敏后的生成结果。setup 只采用实际存在的安装和目录，有多个候选时只选一个并在输出中说明，生成后仍需人工确认 `target_dir` 与 `cloud_sync`。未知字段会直接报错。

| 字段 | 说明 |
| --- | --- |
| `work_dir` | 必填；工具自己的可重建工作目录，生成的配置为 `../build`（即项目的 `build/`） |
| `local_layer` / `common_ui_layer` | 本地层、通用 UI 层 |
| `phrase_example` / `user_phrase_file` | 用户短语模板与目标中的短语文件名 |
| `sync_wait_seconds` | 等待部署/同步完成的上限，默认 180 |
| `frontends[].active` | `true`、`false` 或 `"auto"`（在前端的原生平台上启用） |
| `frontends[].target_dir` | Rime 用户目录，支持 `~/` |
| `frontends[].ui_layer` | 前端专属层 |
| `frontends[].exclude` | 含 `/` 时匹配相对路径，否则匹配文件名；`dir/` 匹配整个子树 |
| `frontends[].commands` | 部署/同步的 `executable` 与 `args`，不经过 shell |
| `frontends[].sync_completion` | `state`（Squirrel 默认）、`log`（Weasel 默认）或 `none` |
| `frontends[].sync_log_dir` | 覆盖前端日志目录 |
| `cloud_sync` | `unison`、`one_drive_dir`、`i_cloud_dir` |

相对路径相对配置文件所在目录解析。目标目录与云目录必须解析为绝对路径。

## 仓库中的配置

每个前端的配置按以下顺序叠加，后面的层覆盖前面的层：上游方案与词库 → `config/local/` → `config/common/` → `config/frontends/<前端>/`。

| 路径 | 内容 |
| --- | --- |
| `config/local/wanxiang.custom.yaml` | 万象主方案补丁：全拼、7890 选词、10 个候选、置顶短语库 |
| `config/common/default.custom.yaml` | 方案列表与方案选单热键 |
| `config/common/wanxiang_phrase.custom.yaml` | 置顶短语库的编译入口 |
| `config/frontends/squirrel/`、`weasel/` | 外观与按应用的中英文设置 |
| `config/frontends/hamster3/include_keyboard_rime_files.txt` | Hamster3 键盘回传规则 |
| `resources/ios-csheng/` | Hamster 皮肤源码；`make -C resources/ios-csheng pack` 生成 `*.cskin`（不进 git） |

层目录只接受 `.yaml`、`.yml`、`.txt`、`.json` 文件，且路径中不能有隐藏文件或目录。编辑器的临时文件（例如 Vim 的 `.swp`）会让预检失败，关闭编辑器后再运行即可。

### 用户置顶短语

`config/local/custom_phrase_user.dict.yaml` 是短语的唯一来源，不进 git，也不打包。它存在时，update 会把它覆盖分发到所有前端；不存在时，目标中已有的短语文件保持不动，目标中缺少时才用模板创建一次。请只在仓库里编辑这个文件，在设备上直接改动的内容会在下一次 update 时被覆盖。

## 目标中的文件

| 类别 | 行为 |
| --- | --- |
| 永不写入 | `user.yaml`、`installation.yaml`、任意层级的 `*.userdb` / `*.userdb.txt`、目标中的 `build/` |
| 只在缺失时创建 | 上游 `custom/**`；用户短语模板 |
| 永不删除 | 上述全部，以及 `lua/`、`tips/`、`custom/`、用户短语文件、`exclude` 命中的路径 |
| `--delete` | 只删除不受保护、且已不再分发的文件；目录仅在为空时删除 |

内容未变的文件不会重写，以免云同步客户端反复上传。

## 部署与同步

Squirrel 部署与同步是否完成，由 Rime 写出的 `user.yaml` 与词库快照判定；Weasel 同步看日志判定，Weasel 部署则无法确认。判定规则和残余风险见 [架构](architecture.md#squirrel-用-rime-写出的状态判定完成并接受稳定期的残余风险)。等待超时会报告哪些项目还没完成，以非零退出，并跳过后续步骤。

Hamster3 只分发文件，部署和同步在手机上操作。

`--cloud-sync`（macOS）的执行顺序是：部署 → Unison → Rime 同步 → Unison。Rime 同步未确认完成时，不执行第二次 Unison。使用前需要先配置好：各台电脑 Rime 的 `installation.yaml` 中，`sync_dir` 都指向同一个 OneDrive 逻辑目录；iOS 端 Rime 指向 iCloud 目录；每台设备的 `installation_id` 保持稳定且互不相同。本工具不写这些文件。

## 运行时文件

| 位置 | 内容 | 删除后果 |
| --- | --- | --- |
| `build/` | 下载缓存、上游内容、stage、Unison 同步记录 | 下次运行时重建；Unison 按首次同步处理 |
| `dist/` | 试用包 | `mise run package` 重建 |

本工具只读取前端日志、目标中的 `user.yaml` 与 `installation.yaml`，以及同步目录中的快照；只写入配置的 Rime 目标，以及 `--cloud-sync` 的两个同步目录。
