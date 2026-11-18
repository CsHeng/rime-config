# 架构

本文说明 rime-config-go 的结构、数据流和关键取舍，以及每个取舍的理由。要解决的问题见 [需求](requirements.md)；具体选项、配置字段、文件边界表和当前验证状态见 [README](../README.md)。

## 形态

本工具是一个本地单进程 CLI，用标准库 `flag` 提供单一命令入口，没有服务、守护进程、TUI、插件框架、自动升级或遥测。选 Go 是为了把 HTTP、JSON、ZIP、文件和进程调用编进各平台的单个二进制，用户不必安装运行时；代价是维护者要负责本机交叉构建（`scripts/package.sh`，`CGO_ENABLED=0`）和随包配置的交付。

工具自己的配置用 JSON，由标准库解析，未知字段与尾随内容直接报错。Rime YAML 按文件分发，不解析也不合并；只有完成判定需要按行读取 `user.yaml` 的 `last_build_time` 和 `installation.yaml` 的 `installation_id`/`sync_dir`。文件保护用路径规则和标准库匹配，不实现 rsync 过滤语法。没有第三方依赖；只有标准库无法合理解决的实际能力缺口才引入依赖。

| 包 | 职责 |
| --- | --- |
| `cmd/rime-config` | 参数、信号、退出码 |
| `internal/config` | JSON 配置、路径解析、校验 |
| `internal/setup` | 检测前端与云同步目录，生成 `frontends.json` |
| `internal/update` | 上游下载、缓存、ZIP、stage、目标分发 |
| `internal/rimesync` | 原生命令、完成判定（状态与日志）、Unison |
| `internal/app` | 编排、选项组合、预检、dry-run 计划 |

日志与诊断写 stderr，预览计划写 stdout；内部函数返回错误，由入口决定退出码。网络和子进程都支持 context 取消。

## 数据流

```text
GitHub Release ──一次查询/下载──▶ build/cache + upstream
                                    │ 每个已启用前端
            upstream → local → common UI → frontend UI
                                    ▼
                          build/stage/<frontend>
                                    │ 路径保护过滤；默认不删除
                                    ▼
                           Rime target_dir
                                    │ 原生命令（异步）
                                    ▼
                    部署 ─▶ [Unison] ─▶ 同步 ─▶ [Unison]
```

上游资源固定为三项：`amzxyz/rime-wanxiang` 的基础方案（tag 前缀 `v`，按 tag 判断版本）和基础词库（tag 前缀 `dict-nightly`，按 asset `updated_at` 判断），以及 `amzxyz/rime-wanxiang-data` 的语法模型（tag 前缀 `LTS`，按 asset `updated_at` 判断）。下载先写入临时文件，在临时目录解压验证后再替换；失败时保留最后一份可用内容且不更新版本标记。ZIP 穿越、链接逃逸和词库扁平化同名冲突直接拒绝。`GITHUB_TOKEN` 只从环境读取，不出现在输出中。

## 关键取舍

### 配置所有权按路径判断，不保存所有权记录

仓库中的层（local、common UI、frontend UI）是配置的唯一来源，会替换目标里内容不同的同名文件；计划把这类替换显示为 `update`，运行摘要统计替换个数。seed（上游 `custom/**`、用户短语模板）只在目标缺失时创建。`custom/`、`lua/`、`tips/`、用户短语文件和配置的 `exclude` 永不删除。

被否决的方案：用 `state_dir` 下的 seed 账本记录“本工具创建过哪些文件”。账本缺失时 `--delete` 只能失败，不同前端同名时还会互相冲突，而路径规则已经足够表达所有保护。只有出现路径规则无法区分的文件归属时，才需要重新考虑这一方案。

### 运行时状态只放在 `work_dir`

`work_dir`（默认 `build/`）存放 cache、upstream、stage 和 Unison 同步记录，可以随时删除。Unison 的记录目录通过 `UNISON=<work_dir>/unison` 固定，忽略外部继承的同名变量；该路径经过符号链接时在副作用之前拒绝，避免写到工作区之外或与用户自己的 Unison 配置混用。删除 `build/` 的代价是下一次 Unison 按首次同步处理：较新的一方优先，删除不会传播。

### 用户短语以仓库本地层为唯一来源

`config/local/custom_phrase_user.dict.yaml` 被 gitignore 忽略且不打包。它存在时由工具覆盖分发到所有前端；不存在时，目标中已有的短语文件保持不动，目标缺失时才用模板创建一次。运行层用 `custom_phrase/dictionary: custom_phrase_user`，编译入口在 `wanxiang_phrase.custom.yaml`，两者必须匹配，部署后才生效。

### Squirrel 用 Rime 写出的状态判定完成，并接受稳定期的残余风险

Squirrel 的 `--reload` 与 `--sync` 只向输入法进程提交异步请求，进程退出不代表完成。librime 用 glog 输出日志，INFO 行会留在空闲输入法进程的缓冲区里，`deployer.cc:97] N tasks ran` 可能要等用户打字后才落盘，几分钟都看不到；只看日志会把已完成的部署误报为超时。

因此完成证据取自 Rime 写出的文件：

- 部署：`user.yaml` 的 `var/last_build_time` 变得不同且不早于提交时间。该值精度为秒，若上次构建就在当前这一秒，工具等到下一秒再提交。
- 同步：每个 `*.userdb` 都在 `<sync_dir>/<installation_id>/` 写出了提交之后的新 `.userdb.txt` 快照。目标没有任何 `*.userdb` 时无法观察，提交前即失败。
- 状态出现后须保持 2 秒不变才算完成，因为快照是原地写出的，`last_build_time` 写入后还有词库升级和清理等短任务。
- 日志是失败通道：维护线程的 ERROR 行会立即落盘，一旦出现即判失败；能看到的任务摘要以其成功/失败计数为准；输入法主线程的打字错误不计入。日志目录缺失或读取出错时直接失败，不能只凭状态文件判定成功。

已接受的残余风险：librime 不写“快照导出完毕”或“维护全部结束”的标记，2 秒稳定期是启发式。若某个快照在写出途中停顿超过 2 秒，或 `last_build_time` 之后的短任务在稳定期之后才失败且日志摘要仍在缓冲中，工具可能先报告完成。用户已选择接受这一风险，换取不必等待日志刷新。出现以下任一情况时应重新评估：librime 提供了明确的完成标记或可靠的日志刷新方式，或实际观察到提前报告完成。

被否决的方案：只认日志摘要（空闲时会长时间超时），以及以进程退出或固定等待作为完成依据（没有任何完成证据）。

### Weasel 以日志判定同步，部署无法确认时失败关闭

`WeaselDeployer.exe` 进程结束时日志已经落盘，因此 `/sync` 以 `%TEMP%\rime.weasel` 中的同步开始行和任务摘要判定。`/deploy` 会忽略任务结果（Weasel 0.17.4 `Configurator::UpdateWorkspace`），工具明确报告“无法确认部署成功”、非零退出，并且不执行后续同步。Windows 日常使用 `--no-redeploy` 更新文件，再在托盘中手动部署。

### macOS 云同步交给 Unison

工具不实现双向同步算法，而是直接调用本机 Unison：`-auto -batch -prefer newer -times -perms 0`，并忽略 `.DS_Store` 与 `*.tmp`。多个前端共用同一组 Unison 运行；dry-run 只显示命令，不运行 Unison，也不声称列出了云端差异。同步对象是 Rime 导出与合并的 `.userdb.txt` 快照，不直接读写运行中的数据库。

## 配置生成与交付

`--setup` 是唯一会写配置的路径：它检测 Squirrel、Weasel、Hamster3 以及 OneDrive/iCloud 同步目录，只写 `config/frontends.json`，家目录路径写成 `~`。检测采用保守策略，不猜测缺失的前端，也不合并有歧义的候选。`config/frontends.json.example` 是脱敏后的生成参考。

交付包由 `scripts/package.sh` 按显式公共资产清单复制，排除用户配置、个人短语、userdb、日志、隐藏文件和皮肤。`mise.toml` 与 `scripts/mise-run.sh` 只是调用 `dist/` 二进制的薄包装，行为由二进制决定。

## 接口依据

- [Squirrel Main.swift](https://github.com/rime/squirrel/blob/master/sources/Main.swift) 与 [SquirrelApplicationDelegate.swift](https://github.com/rime/squirrel/blob/master/sources/SquirrelApplicationDelegate.swift)：`--reload`/`--sync` 只发送异步通知。
- [librime deployment_tasks.cc](https://github.com/rime/librime/blob/master/src/rime/lever/deployment_tasks.cc)：`WorkspaceUpdate` 写入 `last_build_time`，用户词库快照导出到 `sync_dir/installation_id`。
- [Weasel Configurator.cpp](https://github.com/rime/weasel/blob/master/WeaselDeployer/Configurator.cpp)：`/deploy` 不返回任务结果。

上游源码只能说明接口行为，不能替代在实际安装版本上的验证；已在本机验证的版本记录在 README。
