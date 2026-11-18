# rime-config-go

一个独立的 Rime 外部工具：更新万象（`amzxyz/rime-wanxiang`）资源，叠加本仓库维护的配置，分发到 Squirrel、Weasel、Hamster3，再调用原生部署和用户词库同步；在 macOS 上还能用 Unison 同步 OneDrive 与 iCloud 两个同步目录。每个平台只需一个可执行文件，不依赖 Go、PowerShell、rsync 等运行时。

## 快速开始

```sh
mise run package   # 构建 dist/ 下的二进制
mise run setup     # 检测本机前端，生成 config/frontends.json
mise run plan      # 预览会改动什么
mise run update    # 下载、分发、部署、同步
mise run sync      # 只同步用户词库
```

个人置顶短语放在 `config/local/custom_phrase_user.dict.yaml`（不进 git），可参照 `config/custom_phrase_user.dict.yaml.example` 创建。

## 状态

- 已验证：在 macOS（Squirrel 1.1.2）上对真实 `~/Library/Rime` 完成了更新、部署和用户词库同步。
- 未验证：真实 Windows 运行、Hamster3 分发（本机配置为 `active: false`）、`--cloud-sync` 的 OneDrive/iCloud 实际往返，以及跨设备词条验收（见[需求](docs/requirements.md#验收) V1–V4）。
- 已知风险：Squirrel 的完成判定在 Rime 状态写出后等 2 秒稳定期，属于经验判断，极端情况下可能提前报告完成（见[架构](docs/architecture.md#squirrel-用-rime-写出的状态判定完成并接受稳定期的残余风险)）。

## 文档

- [使用参考](docs/usage.md)：mise 任务、配置字段、仓库配置、文件保护规则、运行时文件。
- [需求](docs/requirements.md)：目标、约束、用户数据边界、验收。
- [架构](docs/architecture.md)：结构、数据流、关键取舍及理由。

## 开发

需要 Go 1.26 或更高版本，无第三方依赖。

```sh
gofmt -l . && go vet ./... && go test ./...
scripts/package.sh   # 交叉构建 Windows amd64、macOS arm64/amd64 到 dist/
```

测试只使用临时目录和假进程，不会触碰真实 Rime、OneDrive 或 iCloud。
