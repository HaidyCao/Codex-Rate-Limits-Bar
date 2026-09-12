# 回归验证

在仓库根目录执行 `make verify`，依次运行常规 Swift 测试、CLI/MCP 集成、AppKit 视图检查和独立应用资源检查。验证不需要 Codex 登录，也不安装应用、切换账户或修改用户日志。

## 命令

| 命令 | 内容 |
| --- | --- |
| `make verify` | 常规测试、CLI/MCP、AppKit、应用资源的统一入口 |
| `make test` | 快速 Swift 回归；排除需要显式开启的大日志测试 |
| `make verify-local-usage` | 打包应用，用假 app-server 和临时日志验证 CLI/MCP |
| `make verify-ui` | 生成 CLI/MCP 样例，编译实际 AppKit 视图并检查、渲染 |
| `make verify-bundle` | 将 `.app` 复制到临时位置，禁止访问 `.build` 后读取内置价格 |
| `make benchmark` | release 模式扫描合成的 256 MiB 日志，报告耗时、内存及缓存大小 |
| `make benchmark BENCHMARK_MIB=1024` | 使用约 1 GiB 合成日志；允许范围为 16～4096 MiB |
| `make verify-live` | **访问调用者的真实 Codex 账户**，用于主动选择的现场检查 |

需要 macOS、Swift 6、Xcode 工具链及 Python 3，无第三方 Python 依赖。AppKit 离屏渲染仍需可用的 macOS 图形会话；没有图形会话的 CI 可以运行 `make test verify-local-usage verify-bundle` 和独立的性能任务。验证退出码非零即失败，子进程错误输出会保留。

`make verify` 不再隐含真实账户检查；原来的现场读取已拆到 `make verify-live`。`CODEX_HOME`、`CODEX_BIN`、自定义价目表等调用者环境不会影响隔离样例。`verify-live` 则保留调用者环境；要与默认桌面应用的 `.codex` 来源一致，可执行 `env -u CODEX_HOME make verify-live`。

## 隔离范围

运行时使用假凭据和假 app-server，Foundation 的用户目录通过 `CFFIXED_USER_HOME` 指向临时目录，认证、应用缓存及日志写在该目录下；不会重新定义调用者的 `HOME`。进程继承的 Codex 配置和 OpenAI API 环境变量会被移除。测试进程和它们的子进程由 macOS sandbox-exec 禁止联网，未预期的官方请求会失败。SwiftPM 自身的嵌套 sandbox 与外层 sandbox 不兼容，因此该验证进程关闭 SwiftPM 的内层 sandbox，外层禁止联网的规则仍生效。

系统语言、字体及操作系统版本可能影响显示和耗时。命令行样例把时区选在接近正午的位置，避免测试开始时间接近午夜造成误报；跨午夜和时区变更使用 Swift 测试中的显式时钟验证。

CLI/MCP 测试既包含无持久化缓存的隔离扫描，也包含启用缓存后的真实进程退出、重启、归档移动、重建及同 home 账户切换。性能测试生成固定大小的缓冲区并重复写入临时文件，结束后删除输入，不读取真实会话。

## 回归覆盖

| 场景 | 主要测试 |
| --- | --- |
| 账户切换、额度类型、提醒去重、认证来源 | `AccountContextTests`、`QuotaForecastTests`、CLI/MCP 持久化样例 |
| 同大小覆写、截断、改名副本、跨 home、归档移动 | `ScannerIdentityTests`、`ScannerEquivalenceTests` |
| 跨午夜、fork 导入、模型/模式切换、重启 | `LocalUsageScannerTests`、`ScannerEquivalenceTests` |
| 不可读/缺失文件、非法 JSON、合法空白、未完成记录 | `ScannerCompletenessTests`、CLI/MCP 样例 |
| 周金额稳定性、时间对齐、样本失效和重算 | `WeeklyQuotaEstimatorTests`、`WeeklyQuotaSamplingTests` |
| 价格版本、别名、未知型号、默认费率假设 | `PricingCatalogTests`、价格估算测试、CLI/MCP 样例 |
| 重试、独立错误、超时、网络恢复状态、迟到结果 | `RefreshStateTests`、假服务超时清理/恢复样例 |
| 缺失归档目录创建后的路径别名与历史保留 | `AccountContextTests`、`ScannerEquivalenceTests`、CLI/MCP 持久化样例 |
| 统计不可用时的 GUI credits 提示 | `VerifyMenu.swift` 使用 CLI/MCP 的不可用数据样例 |

`ScannerEquivalenceTests` 使用独立缓存：一侧持续增量读取并重启，另一侧每次完整重建。对比包含 tokens、事件计数、明细、API/credits 金额、诊断、价格信息和周观察；只排除随运行耗时变化的 `ageSeconds`。同时断言独立已知的 tokens 和金额，避免两个实现路径一起算错却通过比较。不能用删除日志或同大小覆写来“证明缓存复用”。

## 产物和性能

产物写到被 Git 忽略的 `.build/verification/`：

- `fixtures/`：假数据的 CLI/MCP JSON 快照。
- `menu/`：完整、未知模型、部分扫描、不可用、接口失败、保留的过期数据、清空账户等 7 种场景的浅色/深色 PNG。
- `benchmark.json`：输入大小、冷扫描、无变化增量、追加、重启和重建耗时，以及进程峰值 RSS、缓存字节数和结果对比。

AppKit 检查使用 `MenuBarApp.swift` 中的实际视图；`main.swift` 仅保留应用启动入口。验证入口不启动菜单栏、登录项或通知。自动检查共享快照的显示标签和状态是否传入视图，生成图像供排版检查；PNG 成功生成不等于已经自动判断所有像素的正确性。

大日志测试对 tokens 和全量/增量金额一致性作硬断言，缓存应小于 1 MiB、测试进程峰值 RSS 小于 256 MiB，以识别意外的整文件或逐事件历史保留。耗时只记录，不使用依赖机器速度的固定通过阈值。RSS 是整个测试进程的高水位，包含生成样例及测试框架开销。合成大日志偏重流式读取和缓存行为，不能替代复杂真实会话的所有性能特征。

## 人工验收

修改视图时检查 `menu/` 产物中的截断、重叠、对比度和过期提示。安装后还需按[刷新恢复说明](refresh.md#验证)检查真实菜单跟踪、断网、睡眠唤醒及测试账户切换；这些系统事件不由默认验证自动触发，也不应将离屏截图视为真实事件验收通过。
