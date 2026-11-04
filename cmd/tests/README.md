# 场景测试 (cmd/tests/)

在包含空格与中文的临时沙盒目录中运行真实入口脚本（`cmd/update.sh` / `cmd/update.ps1` /
`cmd/sync-userdict.sh` / `cmd/frontends.sh`），不接触真实 Rime 安装、云目录或 installation_id。
假前端命令 `fake-cmd.sh` 把收到的参数与关键环境写入 `$FAKE_LOG`，可用 `FAKE_FAIL_ARG` /
`FAKE_EXIT` 注入失败。

## 运行

```bash
bash cmd/tests/run-tests.sh              # bash 侧（需要 jq、rsync、pwsh；Unison 场景可选）
pwsh -NoProfile -File cmd/tests/run-tests.ps1   # PowerShell 侧（需要 pwsh 7+）
```

两个 runner 都会自建并清理临时目录；失败时保留沙盒并打印路径（pwsh 侧）或断言列表（bash 侧）。

## 覆盖范围

- **配置选择**：同一份含 auto/true/false 的 frontends.json，bash 与 pwsh 得出相同 active 前端集合。
- **--sync-only / -SyncOnly**：
  - 离线可用：无 `build/`、PATH 隐藏 yq/bash/rsync/curl/jq/unzip、代理指向黑洞，仍能把配置中的
    参数（如 `/sync`）原样交给假进程；
  - 仅有 iOS 前端（无 sync_cmd）时退出非零并明确「未完成」；
  - 与更新专用选项（init/delete/target/no-download/no-sync）组合在副作用前拒绝。
- **云桥链路（macOS bash）**：`--sync-only --cloud-sync` = 前桥接 → Rime 同步提交 → 后桥接缺口
  （退出码 75 + 人工步骤）；前桥接失败不继续同步；Rime 失败报告前端/阶段/退出码；dry-run 只输出步骤。
- **sync-userdict.sh**：dry-run 不启动 Unison、零修改；目录缺失失败可见；真实 Unison 场景
  （双端新增/修改、非冲突删除、冲突 prefer newer）使用独立临时目录对与独立 `UNISON` 归档目录。
- **过滤引擎（pwsh）**：目录感知遍历；`user.yaml`/`installation.yaml`/嵌套 `*.userdb/`/`build/`/
  `lua/tips/`/`custom/` 在复制、显式 `-Delete`、dry-run 下内容不变；多余文件默认保留、显式删除只影响
  允许项；`-Init` 只补缺失；dry-run 不创建目标、不生成用户短语文件、不调用 hook；短语示例只进 stage。
- **目标校验**：多前端 + 覆盖目标拒绝；非 dry-run 覆盖目标必须同时关 redeploy/sync；stage/模板/upstream
  与目标重叠拒绝；多前端同目标拒绝（含 `..` 等价路径）；**全部在任何 build 目录创建、下载、云桥或目标写入
  之前完成**（拒绝后零侧副作用）。
- **hook 预检**：本次启用的 redeploy/sync 可执行文件在任何写入/云桥之前预检（关闭的 hook 不要求存在）。
- **后桥接提示**：`--config` 外部配置下，退出码 75 的提示命令可直接复制执行且后桥接同一对目录。
- **参数边界**：空字符串参数与内嵌换行原样传递到真实进程（ARGC/ARGV 逐项断言）。
- **交叉核对**：同一场景下 pwsh 过滤引擎与 Bash+rsync（当前项目 filter）产出相同的目标文件集合与内容。
- **.env**：只从所选配置目录加载，不误读脚本目录或真实私有文件。
- **Bash debug 日志**：多前端初始化/更新及 dry-run 中，rsync 路径、runtime、版本各输出一次，保留实际调用参数；sync-only 不探测 rsync。

## 已知边界 / 未验证项

- **Windows 原生行为**：本套件在 macOS 的 pwsh 7 上运行。Windows 原生文件系统/进程行为
  （`C:\` 路径、`WeaselDeployer.exe`、注册表、真实小狼毫）需要真实 Windows 机器验证；
  在那之前 PowerShell 侧结果不构成 Windows 交付证据。
- **Squirrel `--sync` 无完成信号**：上游 `Main.swift` 只投递分布式通知后退出，运行中的 Squirrel
  处理后不发任何事件/日志。因此 macOS 云桥链路停在「已提交」（退出码 75），后桥接需手动执行
  `./cmd/sync-userdict.sh`；这是已披露的能力缺口，不是待修复的 bug。
- **Weasel `/sync`**：上游 `Configurator.cpp` 在 `sync_user_data()` + `join_maintenance_thread()`
  完成后才退出，因此 `-SyncOnly` 以退出码作为完成结果。
- 缺 Unison 时跳过 b10 并打印 `UNVERIFIED`，不算通过。
