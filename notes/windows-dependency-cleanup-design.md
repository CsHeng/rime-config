# Windows 依赖收敛与用户词库同步设计

状态：设计基线，相关脚本、测试和文档已实施；当前交付范围与未验证项见 [实施计划](windows-dependency-cleanup-plan.md)。下文“当前实现与目标的差别”记录设计时的旧实现，不代表现有代码。

## 目标与边界

- D1 保留现有 Bash/macOS 工作流，Windows 继续使用 PowerShell 7；降低低频 Windows 使用的安装维护成本，不引入编译发布链路。
- D2 Windows 配置更新及 Rime 用户词库同步只需要 PowerShell 7 和已安装的小狼毫，不要求 yq、Git Bash、rsync、curl、jq、unzip。
- D3 Windows 和 macOS 的 Rime 都使用同一 OneDrive 账号下的同一个逻辑同步目录；macOS 额外桥接该目录与 iCloud，供 iOS 使用。用户词库同步是交付要求，不是可静默跳过的附加功能。
- D4 本仓库独立拥有脚本、配置模板、测试和文档；不读取其他工具仓库的源码、配置、缓存或构建输出，不引入共享 SDK、子模块、符号链接或自动跨仓库配置同步。
- D5 原设计阶段仅交付设计、计划和必要的文档纳管，不授权脚本实施或真实部署、同步。后续实施及提交范围见实施计划；真实 Rime、OneDrive、iCloud 和用户私有配置的修改仍需对应授权。

## 当前实现与目标的差别

`cmd/update.ps1` 已用 PowerShell 原生 HTTP、JSON、ZIP 和文件操作替代 curl、jq、unzip、rsync；yq 仅用于读取 `cmd/frontends.yaml`。Bash 的 `cmd/frontends.sh` 和 `cmd/sync-userdict.sh` 也读取这份 YAML，因此不能只给 Windows 再添加一份独立的 JSON 配置而留下两个配置真源。

现有 PowerShell 过滤器先递归枚举，再逐项判定，排除 `*.userdb` 目录并不能保护已枚举的内部文件。模板中的带引号命令字符串与 PowerShell `Invoke-Expression` 也不天然兼容。`-CloudSync` 当前寻找并不存在的 `sync-userdict.ps1`，因此没有实现可用的 Windows 云桥。

受跟踪的 `cmd/squirrel/installation.yaml` 仍把 `sync_dir` 指向 iCloud，`cmd/weasel/installation.yaml` 指向 OneDrive。这不是当前用户机器配置的运行时证明，也不符合本次确定的目标拓扑。实施要修订模板并提供明确的迁移步骤，不能借 `--init` 覆盖已有 installation 或重置设备身份。

## 配置和依赖决策

选择一份用户本地 `cmd/frontends.json`，随仓库提供 `cmd/frontends.json.tmpl`。PowerShell 使用 `ConvertFrom-Json`，Bash 使用现有 jq；删除更新/同步入口对 yq 的运行时依赖。Rime 的方案、patch、词库及 installation 仍是 YAML，不做格式迁移。

入口支持显式 `-Config` / `--config`，默认仍为本仓库 `cmd/frontends.json`；显式配置路径相对调用者 cwd，配置内路径相对配置目录。若保留 `.env` 加载，只读取所选配置目录的 `.env`，不因 fixture 配置而误读真实私有文件。测试据此使用完整独立的配置和假进程。

| 运行场景 | 所需通用工具 |
| --- | --- |
| Windows 更新、Rime 同步或仅同步 | PowerShell 7 |
| macOS 配置更新 | Bash、rsync、curl、jq、unzip |
| macOS 仅调用 Rime 同步 | Bash、jq |
| macOS OneDrive ↔ iCloud 桥接 | Bash、jq、Unison |

依赖按实际操作检查：仅同步不应要求上游下载工具。OneDrive/iCloud 客户端和输入法是系统集成前提，不算被消除的依赖。yq 如用于一次性迁移，只是可选的开发机转换工具，不成为新安装前提。

保留 `auto`、`frontends`、`userdict_sync` 等现有业务结构和 `active: true/false/"auto"` 语义。重命名 YAML 专用变量及读取函数，不保留两套运行时解析路径。JSON 不支持注释，解释放在 README 和模板配套说明中。

`redeploy_cmd` 和 `sync_cmd` 改为 `{ "executable": "...", "args": ["..."] }` 对象；直接传参数数组调用，不拼接 Shell 字符串。macOS 示例为 Squirrel 可执行文件配 `--reload` / `--sync`，Windows 示例为 WeaselDeployer 配 `/deploy` / `/sync`。特殊 Shell 需求只能显式把 Shell 配成 executable，不能隐式 eval 任意字符串。

配置字段中的相对文件路径相对配置文件目录解释；目标及云目录建议使用原生绝对路径或 `~/`。保留现有 `/c/...` 输入转换以减少 Windows 迁移成本，但推荐原生 Windows 路径；不再要求 Windows 用户为 PowerShell 安装 Unix 工具链。配置模板缺失、字段类型错误、命令找不到应在本次操作写入前明确失败。

迁移不覆盖私有配置：从旧 YAML 转换到旁置临时 JSON，核对前端启用、路径、云目录和命令对象后再选择新文件；旧文件保留作人工恢复输入，但新入口不自动回退读取它。README、AGENTS、忽略规则和命令示例在实施时同步更新；本提案不把未来行为写成现状。

## 用户词库链路

```text
Windows Rime ── /sync ── Windows 本机 OneDrive 目录
                                  ⇅ 同账号、同逻辑目录，OneDrive 客户端传输
macOS Rime   ── --sync ── macOS 本机 OneDrive 目录
                                  ⇅ Unison，macOS 本地目录桥接
                            macOS 本机 iCloud 目录
                                  ⇅ iCloud 客户端 / iOS Rime 同步
                               iOS Rime
```

Rime 的 `installation.yaml/sync_dir` 与本工具的云目录配置是两类设置，必须对齐。桌面端各自指向本机 OneDrive 的对应目录；iOS 使用 iCloud。每台设备保留唯一且稳定的 `installation_id`，同步的是 `RimeUserSync/<installation_id>/*.userdb.txt` 等 Rime 快照，不复制或合并运行中的 `*.userdb` 数据库。

提供不下载、不组装 stage、不 redeploy 的 `-SyncOnly` / `--sync-only` 路径，Windows 调用 Weasel `/sync`，macOS 调用 Squirrel `--sync`。普通 update 默认继续进行 Rime 同步；`-NoSync` / `--no-sync` 是用户主动选择的仅配置更新。

macOS 的完整跨云入口使用 `--cloud-sync`，期望顺序是前桥接 → Rime 导入/导出完成 → 后桥接：先拉入 iOS 快照，再让本机 Rime 导入/导出，最后把本机快照送回 iCloud。多前端更新时整次调用只执行一组前后桥接，iOS 前端只有文件分发，没有本机 Rime 可执行命令。

必须区分命令进程退出和输入法内部工作完成。Squirrel 公开源码中的 `--sync` 只发送异步通知，`--reload` 也不是同步完成屏障；不能发送通知后立即执行下一阶段并报告完整成功。实施先核对实际支持版本的日志/事件完成边界，使用有界、只读的观察等待明确成功/失败，不用固定 sleep 或目录短时稳定代替。没有可信完成信号的版本只能报告已提交/待完成并给出完成后手动桥接步骤，不能把自动闭环标为已交付；该限制必须向试用者明确披露。Weasel `/sync` 的上游实现等待维护线程，但也要检查子进程结果。

接口依据：[Squirrel Main.swift](https://github.com/rime/squirrel/blob/master/sources/Main.swift)、[SquirrelApplicationDelegate.swift](https://github.com/rime/squirrel/blob/master/sources/SquirrelApplicationDelegate.swift)、[Weasel Configurator.cpp](https://github.com/rime/weasel/blob/master/WeaselDeployer/Configurator.cpp)。这些是上游源码证据，不是对用户已安装版本的运行验证。

- D6 Windows 不需要 Unison；显式传 `-CloudSync` 应在副作用前报错，说明该桥接仅在 macOS 运行，不能再警告后假装完成。
- D7 `--cloud-sync` 与 `--no-sync`、`--sync-only` 与初始化/删除/目标覆盖等更新专用选项组合应明确拒绝；缺少必需命令、桥接脚本、云目录或同步命令失败均返回非零。
- D8 Unison 继续负责有状态双向同步，保留当前 `-times`、`-perms 0`、`-prefer newer`、忽略 `.DS_Store` 和 `*.tmp` 的策略；Rime 负责词条合并。Unison 不是词典内容合并器，也不直接访问云 API。
- D9 OneDrive/iCloud 的远端传输具有最终一致性。本机命令成功只能证明本机步骤成功，不能宣称远端设备已收齐；完整验收要等待客户端上传/下载及手机执行 Rime 同步。

`cmd/sync-userdict.sh` 保持单独可运行的 macOS 桥接入口。Windows 仅同步复用更新脚本内部的 Rime 同步函数，不再寻找同名 PowerShell 云桥。云桥 dry-run 只展示目录、策略和待调用步骤，不运行 Unison、不声称已算出准确的云端文件差异；移除依赖 sleep/timeout/模拟交互的伪预览路径。

## 文件分发与数据保护

保持已有 stage 分层、上游版本 marker、前端过滤文件和默认不删除策略，不把这次改动扩大成通用同步引擎重写。PowerShell 只支持项目实际使用的规则；遇到不支持的规则报错，不能静默忽略。过滤目录时必须停止遍历该子树，复制和删除使用同一套保护判定。

保护 `user.yaml`、`installation.yaml`、任意层级 `*.userdb/` 的完整子树、`build/`、`lua/tips/`，以及前端 filter 排除的内容。初始化只写缺失文件；清理只在显式 `Delete` 下执行，不能递归删除包含受保护内容的祖先目录。拒绝源目标相同或包含重叠，以及同次调用将多个前端写入一个覆盖目标；保留 `-Target` 时必须只选中一个前端。覆盖目标只用于文件分发，非 dry-run 时必须同时关闭 redeploy 和 sync，否则预检拒绝；改变复制路径不能改变 Squirrel/Weasel 命令实际管理的用户目录，不能让沙盒试用意外触发真实输入法。

本地 stage/cache 是可重建状态；短语库、目标用户状态及云快照不是。dry-run 可以刷新本仓库自己的缓存/stage，但不创建或修改目标、不生成用户短语文件、不调用 Rime/Unison；缺少短语库时在 stage 使用示例，实际更新才按现有约定创建用户副本。

Hamster3 的 `include_keyboard_rime_files.txt` 必须保留 `.*[.]userdb.*$`，不能引入会把旧 custom patch 回传覆盖新 patch 的宽泛规则。手机端仍需用户执行重新部署或同步，工具不冒充已在 iOS 完成这些操作。

## 独立试用与验收

两种工具可以安装共存，但不能同时写同一个 Rime 目标或同时桥接同一对云目录。先用各自独立 fixture/目标预览，再由用户顺序切换真实目标；同一设备的 installation 身份不能因为切换工具而改变。外部 Rime 和云目录是业务集成点，不意味着仓库之间存在依赖。

验收以业务场景为准：Windows 隐藏 yq 等工具后仍能从真实入口更新并调用 `/sync`；两种脚本读取同一 JSON 得到相同前端和参数；带中文/空格路径可用；受保护目录深层文件在复制、删除、dry-run 下保持不变；仅同步不访问下载链路；Mac 桥接顺序为前桥接、Rime、后桥接，失败可见。真实跨设备验收使用可识别的测试词条，等待 OneDrive 客户端后确认 Win ↔ Mac，再确认 Mac ↔ iOS，不能用文件存在替代词条导入结果。

## 交付与非目标

实施交付是本仓库独立可运行的脚本、模板、测试和迁移说明，不包含 Go、安装器、后台服务、定时任务或新增包管理体系。项目维护者承担脚本及 jq/rsync 等 macOS 现有依赖的维护；用户根据实际试用决定是否继续保留本方案。

本轮设计没有授权执行真实同步或迁移现有 `sync_dir`。后续实施先完成临时目录验证；本机 Rime、OneDrive、iCloud 的切换与跨设备测试需要匹配的实际执行授权及可用设备。
