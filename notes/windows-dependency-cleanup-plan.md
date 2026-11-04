# Windows 依赖收敛与用户词库同步实施计划

状态：已实施（P1–P4 代码、测试与文档已交付；真实验收 V1–V3 与真实 Windows 运行仍待对应授权/设备）。行为依据为 [设计](windows-dependency-cleanup-design.md)；执行者可以调整内部函数及测试组织，不得改变用户词库保护、OneDrive 拓扑和仓库独立性。

## 交付目标和执行边界

交付本仓库独立可用的 PowerShell 7 Windows 入口、保留的 macOS Bash 入口、单一 JSON 配置及必要同步流程。Windows 无 yq/Unix 工具仍可更新和调用 Rime `/sync`；macOS 继续使用现有工具完成 OneDrive ↔ iCloud 桥接。

本计划本身不授予执行权限。当前用户已要求检查等价入口的重复日志问题，并对工作区改动执行 `smart-commit and push`，因此当前交付包含修复检查、按业务分组提交和推送。验证范围仍为本仓库源码、临时目标、离线资源和假命令；不改用户私有配置、真实 Rime installation、云快照或 installation_id，不运行真实输入法部署/同步或安装新工具。真实切换与跨设备验收仍需对应授权和设备。

## P1 单配置、无 yq 的最小 Windows 路径

写入范围：`cmd/frontends.json.tmpl`、`cmd/frontends.sh`、两个 update 入口的配置读取及调用边界、`cmd/sync-userdict.sh` 的配置读取、忽略规则和对应测试。首个有用动作是建立一个只启用 weasel 的临时 JSON 配置和假 WeaselDeployer，随配置改动一起加入最小 SyncOnly 分支，贯通真实 PowerShell 入口的前端选择及 `/sync` 参数传递，不先搭建通用框架。

- P1.1 把模板中的 auto、active、target、UI 层、filter 路径和 cloud 目录迁入 JSON；`redeploy_cmd` / `sync_cmd` 用 executable 和 args 对象。模板内文件路径改为相对 `cmd/`，原来的 `cmd/weasel/...` 需相应迁移，不能仅替换文件扩展名。
- P1.2 PowerShell 一次读取并验证 JSON，删除 yq 外部调用及每属性重复解析；Bash 包装改用 jq，并更新所有 `_yq` 调用和 `strenv(F)` 查询。同步脚本不能成为残留的 yq 依赖入口。
- P1.3 原生调用可执行文件并保留参数边界，检查进程退出码；不能把字符串命令交给 Invoke-Expression/eval，也不能仅凭进程启动就记录同步成功。对 Squirrel、Weasel 命令的同步/等待行为应核对实际接口，异步提交不得冒充已完成词条合并。
- P1.4 新 JSON 本地文件及转换临时文件不入 Git。提供一次性迁移说明：旁置转换、人工核对路径和命令对象、主动选择新文件，保留旧 YAML 作人工恢复；新运行时不支持 YAML 回退，不新增两份需要持续维护的用户配置。
- P1.5 使用脚本原生能力或现有工具写小型场景测试，不为这些测试增加 Windows 运行时模块。添加 `-Config` / `--config`，默认指向本仓库 JSON；测试显式选择 fixture 配置且只在该配置目录加载可选 `.env`。最小 SyncOnly 分支直接调用 Rime 同步，不进入下载、stage 或 redeploy。

证据：`pwsh -NoProfile` 下真实脚本入口用 fixture 配置选择 weasel，并把 `/sync` 原样传给假进程；在隐藏 yq、bash、rsync、curl、jq、unzip 的测试环境中不依赖它们。Bash 与 PowerShell 对同一份含 auto/true/false 的配置得出相同选择；缺文件、坏 JSON、错误字段及带空格/中文路径有明确结果。

## P2 可独立执行且失败可见的用户词库同步

依赖 P1 的配置和命令调用边界。写入范围：两个 update 入口的选项/流程、`cmd/sync-userdict.sh`、相关测试；代码和它的场景测试放在同一个实施任务中。

- P2.1 完成并统一 P1 的 `-SyncOnly` / `--sync-only` 行为，绕过上游检查、stage、复制和 redeploy，调用所选桌面前端的 Rime 同步。仅有 iOS 前端且没有可调用桌面 Rime 时，不能把 sync-only 报成已完成。更新默认保留 Rime 同步，主动 no-sync 才跳过。
- P2.2 macOS 完整入口为 `./cmd/update.sh --sync-only --cloud-sync`，普通更新需要完整桥接时用 `./cmd/update.sh --cloud-sync`。整次执行的顺序是前桥接、Rime 同步完成、后桥接；含多个前端时不按前端重复桥接。先核验配置、路径和必需程序，前桥接失败不继续同步，Rime 失败不报整次成功。Squirrel 的异步完成边界要在本任务前段核对支持版本的日志/事件，建立有界只读观察后才能自动串联 redeploy、sync 和后桥接；没有可信完成信号时明确交付缺口及人工步骤，不用 sleep 或进程退出假装闭环。
- P2.3 Windows 的 `-CloudSync` 明确拒绝，不再寻找不存在的 PowerShell 云桥；更新专用开关与 sync-only 的冲突、cloud-sync 与 no-sync 的冲突在副作用前拒绝。下载依赖只在需要下载时检查。
- P2.4 保留 Unison 既有双向状态及冲突策略，不迁移或清理用户现有 Unison 归档。dry-run 不启动 Unison，仅输出待执行目录及步骤；明确它不是精确的云端文件差异预览，移除 timeout、sleep 和伪交互退出链路。
- P2.5 同步命令失败给出前端、失败阶段和非零结果，不仅输出 warning。若底层命令只提交异步工作，输出必须区分已提交与已完成，不用固定 sleep 猜测完成。

证据：假进程记录调用顺序及参数，覆盖正常、前桥接失败、Rime 失败、后桥接失败和 dry-run。sync-only 在没有 upstream/cache 时仍可工作且不请求网络。另用真实 Unison 和独立的临时本地目录测试两端新增/修改、非冲突删除及冲突策略；不连接真实云目录，缺 Unison 时把这项记录为未验证而非通过。

## P3 安全文件分发和仅初始化行为

可在 P1 确立接口后与 P2 分开实施；共享 update 入口由主实施者集成。写入范围：PowerShell 过滤/遍历/删除逻辑、必要的 Bash 参数边界、对应 filter fixture 和文件树场景测试。

- P3.1 改为目录感知遍历，排除目录即跳过完整子树；复制和删除必须共用规则解释。仅覆盖当前项目规则，不实现通用 rsync 引擎；不支持的有效规则需报错。
- P3.2 保护 user.yaml、installation.yaml、嵌套 userdb、build、lua/tips 和前端排除项；删除阶段不能通过删除父目录绕过保护。默认不删除，初始化只补缺失文件。
- P3.3 dry-run 只更新本仓库可重建的 cache/stage，不创建目标、不改用户短语文件、不调用真实 hooks。缺短语时可在 stage 使用示例，非预览执行才按约定生成用户副本。
- P3.4 验证源目标相同、祖先/后代重叠和多前端目标冲突，特别是 Target 覆盖只能用于一个前端；覆盖目标的非 dry-run 必须关闭 redeploy/sync，避免复制到沙盒却调用真实输入法。验证在目标写入或目标目录创建前结束。

证据：用临时文件树断言正常 patch 更新、源缺失目标文件默认保留、显式删除仅影响允许项、深层数据库和状态文件内容不变、已存在初始化文件不被覆盖、dry-run 无目标副作用。用当前项目 filter 配合 Bash rsync 做必要行为交叉核对，但不把旧 PowerShell 的误行为固化成兼容契约。

## P4 集成交付、迁移说明与本地试用包

依赖 P1–P3 的业务路径。更新 `README.md`、`cmd/README.md` 和 `AGENTS.md`，让已验证的真实入口、依赖、JSON 设置、保护边界和同步步骤一致；不搬迁无关历史文档或修改皮肤。

- P4.1 修订受跟踪的桌面 installation 模板，表达各自本机 OneDrive 路径，并说明模板仅供缺文件初始化。提供已有 Mac 从 iCloud sync_dir 切到 OneDrive 的人工步骤：先确认云端本地副本可用并预览桥接，保全现有 installation/快照，用 Rime 同步导出，再使两份本地同步树收敛，最后在明确授权下只改 sync_dir，保留原 installation_id；切换后再次同步验证。不要批量重写或删除任一云目录。
- P4.2 写清实际 installation 与工具 JSON 的区别、同账号还必须使用同一逻辑 OneDrive 文件夹、云客户端最终一致性，以及 iOS 必须手动同步/重新部署。保留 Hamster3 回传规则和置顶短语编译入口。
- P4.3 完成 PowerShell 解析检查、`bash -n`、JSON 解析、现有可用 ShellCheck，以及前述场景测试；不为小改动引入新的 lint/覆盖率平台。Windows 原生文件系统/进程行为必须有真实 Windows 运行证据；本机 macOS 的 pwsh 结果不冒充它。
- P4.4 交付能从独立工作目录运行的入口、fixture 测试和迁移说明；删除自建临时目标/进程，不动预先存在的服务或共享缓存。没有真实跨设备证据时明确写出缺口，不把源码完成称为已完成云端联通。

## 后续真实验收和退出方式

真实验收不在本轮执行。取得相应授权和可用设备后，先备份将改动的 installation 和用户快照，再让用户按顺序运行工具，禁止并发写同一目标或桥接同一对目录。

- V1 Windows 造一个唯一测试词，经 `/sync` 和 OneDrive 下载后，Mac 导入可作为候选；再反向验证一次。检查各物理设备 installation_id 没有变化。
- V2 iOS 造词后执行同步，等 iCloud 本地副本就绪，Mac 跑完整前桥接/Rime/后桥接，确认该词进入 Mac 并可经 OneDrive 到 Windows；再反向确认桌面词进入 iOS。
- V3 修改自定义短语后部署，检查编译产物和候选结果；确认已有 userdb 及 Hamster3 手机自造词没有因部署被清空。

任一步失败先定位该步骤；不得以重新初始化 installation、清空云目录或覆盖数据库恢复。脚本可以向前修复；若配置迁移需要退出，人工恢复保留的配置及已备份的 sync_dir 设置，不倒灌旧 userdb、不删除新快照。用户可以随时停用此工具，但现有云目录和设备身份保持不变。

## 执行组织

P1 是配置共享的前置输入；P2 和 P3 在接口稳定后可独立推进，但涉及同一入口时由主实施者决定串行或整合，不能自动覆盖对方修改。P4 是实际整合点。无需预先固定代理数量、模型、宿主 worktree 或评审轮数。最终以有效功能及数据保护证据接受结果，而不是以任务全部打勾或文档文字一致性接受。
