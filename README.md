# rime-config-go

独立的跨平台 Rime 外部工具：更新万象（`amzxyz/rime-wanxiang`）资源、叠加本仓库维护的配置、安全分发到多个 Rime 前端、调用原生部署与用户词库同步，并可在 macOS 上用 Unison 同步 OneDrive 与 iCloud 两个同步目录。日常运行只需要一个原生可执行文件，不需要 Go、PowerShell 7、Git Bash、yq、jq、rsync、curl 或 unzip。

当前状态：[需求](docs/requirements.md)中的更新、分层、分发、部署、同步与 macOS 云同步均已实现（`cmd/rime-config`），配置内容已从旧版 `rime-config` 按“电脑与手机都只用全拼”的决定迁移到 `config/`。本机 macOS（Squirrel 1.1.2）上已用真实 `~/Library/Rime` 完成更新、部署与用户词库同步，部署与同步完成由 Rime 写入的状态文件确认（见“部署与同步的完成判定”）。Hamster3 分发、`--cloud-sync` 的真实 OneDrive/iCloud 往返、真实 Windows 与跨设备候选词验收尚未完成。程序输出（日志、错误、计划）统一为英文。

- 需求与验收：[docs/requirements.md](docs/requirements.md)
- 架构与关键取舍：[docs/architecture.md](docs/architecture.md)

## 快速试用

1. 解压 `dist/<platform>/<platform>.tar.gz`（Windows 为 `.zip`）到与源码无关的目录。
2. 生成配置：`./rime-config --setup`。它检测本机 Squirrel/Weasel、Hamster3 的 iCloud 用户目录（`iCloud~…Hamster3/Documents/RimeUserData/<方案目录>`）以及 OneDrive/iCloud 同步目录，写入 `config/frontends.json`；已有配置不会被覆盖，`--force` 重建时旧文件保留为 `frontends.json.bak`。家目录内的路径写成 `~`，不写入安装 ID、词库或用户名。
3. 先看计划：`./rime-config --dry-run`。计划中 `copy` 表示新建文件，`update` 表示会替换目标里内容不同的已有文件。
4. 确认后正式运行：`./rime-config`
5. 只同步用户词库：`./rime-config --sync-only`

默认配置路径是 `<可执行文件目录>/config/frontends.json`，显式 `--config` 可以是相对当前目录的路径，因此可从任意 cwd 运行。

## 用 mise 运行（日常）

仓库自带 `mise.toml`；任务会切换到项目根目录执行，并按当前 OS/架构选择 `dist/<os>-<arch>/` 下的二进制：

| 任务 | 作用 |
| --- | --- |
| `mise run setup` | 检测本机前端并生成 `config/frontends.json`；已存在时不覆盖，重建加 `-- --force` |
| `mise run info` | 查看解析到的平台二进制、配置路径与转发参数 |
| `mise run plan` | 预览（`--dry-run`，不写目标、不调用 Rime/Unison） |
| `mise run update` | 日常更新：下载、分发、部署、同步 |
| `mise run sync` | 仅同步用户词库（`--sync-only`） |
| `mise run package` | 重建 `dist/` 下的平台试用包 |

额外参数放在 `--` 之后，例如 `mise run update -- --delete`、`mise run plan -- --no-download`；`--config` 会覆盖默认配置文件。任务使用 `dist/` 中已构建的二进制，改代码后先运行 `mise run package`。

Windows：mise 任务需要 POSIX shell（Git Bash）。由于 Weasel `/deploy` 的结果无法确认，`mise run update` 默认会在部署阶段失败关闭；日常用 `mise run update -- --no-redeploy` 更新文件并执行日志可观察的同步，然后在 Weasel 托盘中手动部署。

## 命令与选项

| 选项 | 作用 |
| --- | --- |
| `--config PATH` | 配置文件；默认 `<可执行文件目录>/config/frontends.json` |
| `--setup` | 检测本机 Rime 前端与云同步目录，生成或预览配置；不触碰 Rime 目标 |
| `--force` | 配合 `--setup`：配置已存在时也按检测结果重建（旧文件保留为 `.bak`） |
| `--sync-only` | 只执行 Rime 同步：不下载、不分层、不部署 |
| `--no-sync` | 普通更新后不执行 Rime 同步 |
| `--no-download` | 完全不访问网络，只使用已有上游内容/缓存；不足则非零退出 |
| `--no-redeploy` | 更新后不调用原生部署（只更新配置） |
| `--delete` | 删除目标中不再分发、且不受保护的文件 |
| `--dry-run` | 只输出计划；不写目标、不创建用户短语、不调用 Rime/Unison |
| `--cloud-sync` | macOS：Rime 同步前后各运行一次 Unison，同步 OneDrive 与 iCloud 两个同步目录 |
| `--target PATH` | 把唯一已启用前端的写入目标改到 PATH（仅沙盒分发；非 dry-run 必须同时关闭部署与同步） |
| `--version` / `-h` | 输出版本 / 帮助（退出码 0） |

互斥与组合规则在副作用之前校验：`--setup` 只能单独使用（可配合 `--dry-run`、`--config`、`--force`）；`--force` 只能配合 `--setup`；`--sync-only` 不能与 `--no-sync`、`--no-download`、`--no-redeploy`、`--delete`、`--target` 组合；`--cloud-sync` 只支持 macOS、需要 `cloud_sync` 配置且不能与 `--no-sync` 组合；`--target` 只允许一个已启用前端。

## 配置

`config/frontends.json.example` 是本机 macOS 配置的脱敏参考，推荐直接运行 `rime-config --setup` 生成。配置中出现未知字段会直接报错（例如已移除的 `state_dir`、`bootstrap_layer`）。字段含义：

| 字段 | 说明 |
| --- | --- |
| `github_api_base` | 上游 API 基址，默认 `https://api.github.com`；仅用于测试注入 |
| `work_dir` | 本工具自己的可重建工作目录（相对配置文件），保存下载缓存、upstream、stage 与 Unison 记录 |
| `local_layer` / `common_ui_layer` | 本地层、通用 UI 层（相对配置文件） |
| `phrase_example` | 用户短语模板，默认 `custom_phrase_user.dict.yaml.example` |
| `user_phrase_file` | 目标中的用户短语文件名，默认 `custom_phrase_user.dict.yaml` |
| `sync_wait_seconds` | 等待异步部署/同步完成的上限，默认 180 秒 |
| `frontends[].active` | `true`、`false` 或 `"auto"`（按 kind 的原生平台启用） |
| `frontends[].target_dir` | 目标 Rime 目录，支持绝对路径与 `~/` |
| `frontends[].ui_layer` | 前端专属层；不写则跳过 |
| `frontends[].exclude` | 简单模式：含 `/` 时匹配相对路径，否则匹配文件名；`dir/` 或前缀形式匹配整个子树 |
| `frontends[].commands` | 原生部署/同步的 `executable` 与 `args` 数组，不经过 Shell |
| `frontends[].sync_completion` | `state`（Squirrel 默认）、`log`（Weasel 默认）或 `none`；Squirrel 与 Weasel 都不接受 `process` |
| `frontends[].sync_log_dir` | 覆盖日志目录（Squirrel 默认 `$TMPDIR/rime.squirrel`，Weasel 默认 `%TEMP%\rime.weasel`） |
| `cloud_sync` | `unison`、`one_drive_dir`、`i_cloud_dir` |

`--setup` 的检测是保守的启发式：只接受实际存在的 Squirrel.app / WeaselDeployer.exe；Hamster3 需要 iCloud 容器下的用户目录已有 YAML 文件（优先已有 `wanxiang.schema.yaml` 的方案目录）；OneDrive 优先 `OneDrive-*/Apps/RimeSync`，iCloud 优先 `com~apple~CloudDocs/RimeUserSync`。存在多个候选时会在输出中说明并只选一个，生成后仍需人工确认 `target_dir` 与 `cloud_sync`。

配置内的相对路径相对配置文件目录解析；`cloud_sync` 与目标目录必须解析为绝对路径。配置错误、层目录与工作目录重叠、目标与配置/工作目录/层目录/其他已选目标重叠、工作区或目标经过逃逸符号链接、层目录或短语模板缺失、找不到必需程序（含非 dry-run 的 Unison）、Squirrel 目标缺少带 `installation_id` 的 `installation.yaml`（同步完成无法观察）都在下载或写入前失败。

## 配置来源与仓库布局

| 路径 | 内容 | 进 git |
| --- | --- | --- |
| `config/local/wanxiang.custom.yaml` | 万象主方案补丁：全拼、7890 选词、10 个候选、默认开启表情、置顶短语库入口 | 是 |
| `config/common/default.custom.yaml` | 方案列表与方案选单热键 `Alt+grave`、选单展开 | 是 |
| `config/common/wanxiang_phrase.custom.yaml` | 置顶短语库的编译入口 | 是 |
| `config/frontends/squirrel/`、`weasel/` | Squirrel/Weasel 外观与按应用的中英文设置 | 是 |
| `config/frontends/hamster3/include_keyboard_rime_files.txt` | Hamster3 键盘回传规则 `.*[.]userdb.*$` | 是 |
| `config/custom_phrase_user.dict.yaml.example` | 用户短语模板 | 是 |
| `config/local/custom_phrase_user.dict.yaml` | 你的置顶短语（可能含地址、电话等） | 否（`.gitignore`） |
| `config/frontends.json` | 本机配置 | 否 |
| `resources/ios-csheng/` | Hamster 皮肤源码（Jsonnet）；`make -C resources/ios-csheng pack` 生成 `resources/ios-csheng.cskin` | 源码进 git，`*.cskin` 不进 |

迁移取舍：旧版的 `wanxiang_english/mixedcode/reverse.custom.yaml` 只是把方案设成全拼，与上游默认相同，未迁移；九键（t9）相关补丁未迁移；旧版 `wanxiang.custom.yaml` 中照抄上游模板的大段默认值未迁移，只保留实际改动。`default.custom.yaml` 改用 `switcher/hotkeys`、`switcher/fold_options` 路径补丁，`switcher` 的其余设置跟随上游。

## 分层与文件边界

每个前端按顺序合成 stage：上游基础方案 → 上游词库（`dicts/`）→ 语法模型 → 本地层 → 通用 UI 层 → 前端 UI 层。后层覆盖前层；仓库各层的文件以仓库为准，会替换目标里内容不同的同名文件（计划中显示为 `update`，运行摘要显示 `replaced existing` 个数）。

| 类别 | 行为 |
| --- | --- |
| 永不写入 | `user.yaml`、`installation.yaml`、任意层级 `*.userdb` / `*.userdb.txt`、目标 `build/` |
| 只补缺失（seed） | 上游 `custom/**`；用户短语模板（仅当仓库与目标都没有短语文件时） |
| 永不删除 | 上述全部，加上 `lua/`、`tips/`、`custom/`、用户短语文件与配置 `exclude` 命中的子树 |
| `--delete` | 只清理未受保护且 stage 不再包含的目标文件；目录仅在为空且不受保护时移除 |

保护按路径判断，不需要任何所有权记录；本工具除 `work_dir` 外不在本机保存状态。保护名比较不区分大小写；stage 内出现大小写冲突路径、或解压出空 ZIP 都直接失败。`exclude` 对目录的匹配同时作用于其全部子孙。仓库维护的层目录只接受 `.yaml`、`.yml`、`.txt`、`.json`，且路径中不允许隐藏段。写入使用临时文件替换，内容未变的目标文件不重写；按 Ctrl-C 取消时删除阶段立即停止。

## 用户置顶短语

`config/local/custom_phrase_user.dict.yaml` 是短语的唯一来源：它被 `.gitignore` 忽略，不进 git；存在时 update 把它覆盖分发到所有前端（Squirrel、Hamster3 等），编辑后重新运行 update 即可生效。仓库里没有这份文件时，目标中已有的短语文件保持不动，目标缺少时才用模板创建一次。在设备上直接修改的短语会在下一次 update 时被仓库版本替换，因此请只在仓库里编辑。

## 部署与同步的完成判定

进程退出不等于部署或词库同步已经完成：

- **Squirrel（macOS）**：`--reload` 与 `--sync` 只提交异步请求。完成由 Rime 写入的状态文件判定（`sync_completion: "state"`）：
  - 部署：`user.yaml` 的 `var/last_build_time` 变化且不早于提交时间。该值精度为秒，若上次构建就在当前这一秒，工具先等到下一秒再提交，保证本次构建可区分。
  - 同步：目标中每个 `*.userdb` 词库都在 `<sync_dir>/<installation_id>/<词库>.userdb.txt` 写出了提交之后的新快照（`sync_dir`、`installation_id` 取自目标的 `installation.yaml`，只读）。目标中没有任何 `*.userdb` 时无从观察，提交前即失败。
  - 上述状态出现后还须保持 2 秒不变才算完成：librime 原地写快照，且 `last_build_time` 写入后还有词库升级、回收清理等短任务。稳定期内出现的维护线程 ERROR 或失败摘要仍判失败。
  - 观察失败需要日志目录：Squirrel 日志目录不存在或读取出错时，提交前或等待中直接失败，不以状态单独判成功。
  - 不能只看日志：Squirrel 的 glog 会把 INFO 行留在进程缓冲里，要等之后再有日志写入（例如开始打字）才落盘，空闲时 `deployer.cc:97] N tasks ran` 可能几分钟都不出现。日志仍作为辅助证据：若能看到任务摘要则以摘要的成功/失败计数为准；维护线程（`running deployment tasks:` 所在线程）写出的 ERROR 行会立即落盘，出现即判失败，输入法主线程的打字错误不计入。
  - 超时（`sync_wait_seconds`）明确报告尚未完成的项目并非零退出，不执行后续步骤。
- **Weasel（Windows）**：`WeaselDeployer.exe` 进程结束时日志已落盘。`/sync` 以 `%TEMP%\rime.weasel` 日志中的 `synchronizing N user dicts.` 与 `N tasks ran: S success, F failure.` 判定；`/deploy` 忽略任务结果（Weasel 0.17.4 `Configurator::UpdateWorkspace`），进程结束后明确报“无法确认部署成功”并非零退出，且不执行后续同步。
- **Hamster3 / Hamster**：桌面只分发文件；手机端自行部署和同步。`--sync-only` 需要至少一个可执行同步的桌面前端。

本机验证（Squirrel 1.1.2）：一次部署 9 秒内写出 `last_build_time`，而对应的 INFO 摘要直到 4 分钟后用户打字才落盘；一次同步 10 秒内依次写出 8 个词库快照，最后一个快照与日志摘要同一毫秒。

## macOS：OneDrive ↔ iCloud 同步（Unison）

`--cloud-sync` 的顺序是：部署（普通更新时）→ Unison 同步两个目录 → Rime 同步 → 再次 Unison 同步两个目录。第一次把 iOS 写进 iCloud 的快照带到 OneDrive，供本机 Rime 合并；第二次把本机 Rime 导出的新快照带回 iCloud。Rime 同步未完成或失败时不执行第二次。

Unison 直接调用，参数为 `-auto -batch -prefer newer -times -perms 0 -ignore "Name .DS_Store" -ignore "Name *.tmp"`。它的同步记录放在 `<work_dir>/unison`（运行时设置 `UNISON`，忽略外部同名环境变量），不读写 `~/Library/Application Support/Unison` 或其中的 `default.prf`。删除 `build/` 会丢失这份记录：下一次运行相当于首次同步，按“较新的一方优先”合并，期间两端的删除不会传播（被删文件会被恢复），这是可接受的代价。`--dry-run` 只显示命令，不运行 Unison，也不声称列出云端差异。

本地验证：真实 Unison 2.54 与临时目录覆盖双向新增、修改、非冲突删除、冲突取较新者、保留修改时间、忽略 `.DS_Store`/`*.tmp`、同步记录只写入指定目录。OneDrive/iCloud 在线传输与 iOS 往返尚未验证。

安装指导：Windows/macOS 的 Rime `installation.yaml` 中 `sync_dir` 指向同一账号、同一逻辑 OneDrive 目录；iOS 端 Rime 指向 iCloud 目录；每台物理设备的 `installation_id` 保持稳定且唯一。本工具不写 `installation.yaml`、不复制 `userdb`。

## 运行时文件位置

| 位置 | 内容 | 删除后果 |
| --- | --- | --- |
| `<work_dir>`（默认 `build/`） | `cache/`、`upstream/`、`stage/`、`unison/` | 可随时删除；下次重新下载、重建，Unison 记录重建 |
| `dist/` | 试用包 | `mise run package` 重建 |
| `$TMPDIR/rime-config-setup-*.json` | `--setup` 校验生成配置时的临时副本 | 用完即删 |

本工具只读访问的外部路径：前端日志目录、Rime 目标中的 `user.yaml`/`installation.yaml`、同步目录中的快照。写入的外部路径只有配置的 Rime 目标与 `--cloud-sync` 的两个同步目录。

## 构建与验证

需要 Go 1.26 或更高版本；没有第三方依赖，因此没有 `go.sum`。

```sh
gofmt -l .
go vet ./...
go test ./...
scripts/package.sh   # 生成 dist/ 试用包
```

`scripts/package.sh` 以 `CGO_ENABLED=0` 交叉构建 Windows amd64、macOS arm64/amd64，只按显式公共资产清单复制 `config/` 中的文件，排除 `config/frontends.json`、`config/local/custom_phrase_user.dict.yaml`、`*.userdb*`、日志、隐藏文件与皮肤。

测试覆盖：配置解析与未知字段拒绝、`--setup` 检测（含 Hamster3 的 `RimeUserData` 目录）、资源下载/复用/恢复/损坏/穿越、分层顺序、seed 只补缺失、按路径的删除保护、替换已有文件的计划与计数、仓库短语文件的分发与设备短语的保留、删除阶段的取消、Squirrel 状态判定（日志被缓冲时仍完成、无状态变化超时、维护线程错误判失败、打字错误不计、同步等待全部快照、快照分段写出期间不判完成、无词库时提交前失败、同一秒内的连续部署、仅有失败摘要无 ERROR 行、摘要之后同批写出的错误、缺少日志目录）、Unison 归档目录为符号链接时在副作用前拒绝、Weasel 日志判定与部署失败关闭、`--cloud-sync` 的步骤顺序与多前端只运行一次、真实 Unison 行为。测试使用临时目录与假进程，不触碰真实 Rime、OneDrive 或 iCloud。

## 已知限制与后续验收

- 交叉编译不能证明 Windows 原生路径与进程行为；真实 Windows 上的更新、`/sync` 日志判定仍待验证。
- Squirrel 的状态判定依据本机 1.1.2 的实际行为（`last_build_time` 写入时机、快照写出顺序）；其他版本若行为不同，会以超时明确报告未完成。
- 状态判定的残余风险（已接受）：librime 不写“快照导出完毕”或“维护全部结束”的标记，2 秒稳定期是启发式。若某个快照写出中途停顿超过 2 秒，或 `last_build_time` 之后的短任务在稳定期之后才失败且日志摘要仍被缓冲，工具可能先报告完成。取舍理由见[架构](docs/architecture.md#squirrel-用-rime-写出的状态判定完成并接受稳定期的残余风险)。
- Hamster3 回传规则来自旧版仓库并与设计一致，但本工具尚未在真机上验证 iOS 回传；本机 `config/frontends.json` 中 Hamster3 默认 `active: false`，确认后改为 `true` 才会写入其 iCloud 目录。
- OneDrive/iCloud 在线传输、Win ↔ Mac 与 Mac ↔ iOS 词条往返仍待真实验收（见[需求](docs/requirements.md#验收) V1–V4）。
- GitHub API 只查询最近 100 个 release；只支持设计中的 3 个资源。
- `exclude` 是简单模式而非 rsync 语法；不实现 YAML 解析，只按行读取 `user.yaml`/`installation.yaml` 中的必要字段。
- 没有服务、守护进程、自动升级或遥测。
