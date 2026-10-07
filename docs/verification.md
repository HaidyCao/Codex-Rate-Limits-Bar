# 回归验证

在仓库根目录执行 `make verify`，依次运行常规 Swift 测试、只读价目表检查、CLI/MCP 集成、AppKit 视图检查、独立应用资源和隔离插件安装检查。验证不需要 Codex 登录，也不安装应用、切换账户或修改用户日志。

## 命令

| 命令 | 内容 |
| --- | --- |
| `make verify` | 常规测试、CLI/MCP、AppKit、应用资源的统一入口 |
| `make test` | 快速 Swift 回归；排除需要显式开启的大日志测试 |
| `make verify-pricing` | 禁止联网、读取账户和写入样例目录，验证价目表健康诊断 |
| `make verify-client-contracts` | 真实日志投影与合成套餐样例，跨进程缓存、CLI/MCP 对比 |
| `make verify-local-usage` | 打包应用，用假 app-server 和临时日志验证 CLI/MCP |
| `make verify-ui` | 生成 CLI/MCP 样例，编译实际 AppKit 视图并检查、渲染 |
| `make verify-bundle` | 将 `.app` 复制到临时位置，禁止访问 `.build` 后读取内置价格 |
| `make verify-plugin-install` | 假 CLI 验证首次安装、重装、损坏配置、命令失败及状态恢复 |
| `make benchmark` | release 模式扫描合成的 256 MiB 日志，报告耗时、内存及缓存大小 |
| `make benchmark BENCHMARK_MIB=1024` | 使用约 1 GiB 合成日志；允许范围为 16～4096 MiB |
| `make verify-live` | **访问调用者的真实 Codex 账户**，用于主动选择的现场检查 |

需要 macOS、Swift 6、Xcode 工具链及 Python 3，无第三方 Python 依赖。AppKit 离屏渲染仍需可用的 macOS 图形会话；没有图形会话的 CI 可以运行 `make test verify-pricing verify-local-usage verify-client-contracts verify-bundle` 和独立的性能任务。验证退出码非零即失败，子进程错误输出会保留。

`make verify` 不再隐含真实账户检查；原来的现场读取已拆到 `make verify-live`。`CODEX_HOME`、`CODEX_BIN`、自定义价目表等调用者环境不会影响隔离样例。`verify-live` 则保留调用者环境；要与默认桌面应用的 `.codex` 来源一致，可执行 `env -u CODEX_HOME make verify-live`。

## 隔离范围

运行时使用假凭据和假 app-server，Foundation 的用户目录通过 `CFFIXED_USER_HOME` 指向临时目录，认证、应用缓存及日志写在该目录下；不会重新定义调用者的 `HOME`。进程继承的 Codex 配置和 OpenAI API 环境变量会被移除。测试进程和它们的子进程由 macOS sandbox-exec 禁止联网，未预期的官方请求会失败。SwiftPM 自身的嵌套 sandbox 与外层 sandbox 不兼容，因此该验证进程关闭 SwiftPM 的内层 sandbox，外层禁止联网的规则仍生效。

系统语言、字体及操作系统版本可能影响显示和耗时。命令行样例把时区选在接近正午的位置，避免测试开始时间接近午夜造成误报；跨午夜和时区变更使用 Swift 测试中的显式时钟验证。

CLI/MCP 测试既包含无持久化缓存的隔离扫描，也包含启用缓存后的真实进程退出、重启、归档移动、重建及同 home 账户切换。性能测试生成固定大小的缓冲区并重复写入临时文件，结束后删除输入，不读取真实会话。

## 回归覆盖

| 场景 | 主要测试 |
| --- | --- |
| 账户切换、额度类型、提醒去重、认证来源 | `AccountContextTests`、`QuotaForecastTests`、CLI/MCP 持久化样例 |
| 提醒取消、开关、接收失败、迟到确认、重试、重启及旧历史兼容 | `UsageRefreshControllerTests`、`QuotaAlertDeliveryTests` |
| 缓存保存失败、无变化重试、并发写入、取消及旧快照兼容 | `CachePersistenceTests`、CLI/MCP/UI 样例 |
| UTF-8 跨块、CRLF、响应边界、超长输出、EOF 及终态保护 | `AppServerCallStateTests`、CLI/MCP 假 app-server 样例 |
| 插件校验、暂存、失败回滚、符号链接、重复安装及子进程清理 | `CodexPluginInstallerTests`、`CodexPluginCommandTests`、`verify_plugin_install.py` |
| 同大小覆写、截断、改名副本、跨 home、归档移动 | `ScannerIdentityTests`、`ScannerEquivalenceTests` |
| 互补副本、汇合与分叉、跨日/跨 home、旧副本缓存、文件头空行 | `CopyReconciliationTests`、CLI/MCP 持久化样例 |
| 跨午夜、fork 导入、模型/模式切换、重启 | `LocalUsageScannerTests`、`ScannerEquivalenceTests` |
| 不可读/缺失文件、非法 JSON、合法空白、未完成记录 | `ScannerCompletenessTests`、CLI/MCP 样例 |
| 周金额稳定性、时间对齐、样本失效和重算 | `WeeklyQuotaEstimatorTests`、`WeeklyQuotaSamplingTests` |
| 价格版本、别名、未知型号、默认费率假设 | `PricingCatalogTests`、价格估算测试、CLI/MCP 样例 |
| 旧模型写入无溢价、272K 边界、跨卡重定价与回滚、缺日志恢复 | `PricingReleaseTests`、`ScannerEquivalenceTests`、`verify_pricing.py`、`verify_client_contracts.py` |
| Cyber 长上下文、历史别名、API 与 credits 独立覆盖、旧未计价量恢复 | `TokenCostEstimatorTests`、`CreditAccountingTests`、`ScannerEquivalenceTests`、CLI/MCP/UI 样例 |
| 重试、独立错误、超时、网络恢复状态、迟到结果 | `RefreshStateTests`、`UsageRefreshControllerTests`、假服务超时清理/恢复样例 |
| 缺失归档目录创建后的路径别名与历史保留 | `AccountContextTests`、`ScannerEquivalenceTests`、CLI/MCP 持久化样例 |
| 统计不可用时的 GUI credits 提示 | `VerifyMenu.swift` 使用 CLI/MCP 的不可用数据样例 |
| token 明细缺失/矛盾、差值传播、明细恢复与旧缓存重算 | `InputValidationTests`、`ScannerCompletenessTests`、`WeeklyQuotaSamplingTests`、CLI/MCP/UI 样例 |
| 累计分项修正、总量回退、后续计价恢复及周暂停原因 | `CumulativeUsageCorrectionTests`、`WeeklyQuotaEstimatorTests`、CLI/MCP/UI 样例 |
| 官方比例缺失、越界整数、非法计数/余额/日期 | `InputValidationTests`、CLI/MCP/UI 样例 |

`ScannerEquivalenceTests` 使用独立缓存：一侧持续增量读取并重启，另一侧每次完整重建。对比包含 tokens、事件计数、明细、API/credits 金额、诊断、价格信息和周观察；排除随运行耗时变化的 `ageSeconds`，按文件路径规范化相同 token 数的排名，并将聚合金额对齐到小数点后 12 位，容纳不同求和顺序的浮点末位差异。同时断言独立已知的 tokens 和金额，避免两个实现路径一起算错却通过比较。不能用删除日志或同大小覆写来“证明缓存复用”。新增价目表升级/回滚样例验证旧未知模型、旧 Fast 倍率和 Ultrafast 模式，核对周分钟桶及官方观察样本保留。

`AppServerCallStateTests` 在包含中日韩文字、emoji 和组合字符的响应上遍历每个字节切分位置，并逐字节推进实际解析器；即时检查完成信号，不依赖睡眠或真实管道分块时机。CLI/MCP 再通过真实管道读取逐字节写入的 Unicode 响应和错误，检查超长行、截断 EOF、无末尾换行及子进程清理。缓冲边界与输出规则见[app-server 输出处理](refresh.md#app-server-输出处理)。

插件安装测试注入命令执行器，检查调用顺序及恢复前后的文件内容；跨进程样例使用会修改配置和缓存的假 CLI，在非默认 `CODEX_HOME` 下验证失败恢复、文件权限及其他插件保留。另以本地 shell 验证 Unicode 错误、输出上限和忽略 SIGTERM 后的超时清理。所有测试均禁止联网，不调用真实 Codex 的安装或卸载命令。恢复边界见[插件安装与恢复](plugin-installation.md)。

## 产物和性能

产物写到被 Git 忽略的 `.build/verification/`：

- `fixtures/`：假数据的 CLI/MCP JSON 快照。
- `plugin-install.json`：7 个隔离安装样例的命令顺序及通过状态。
- `menu/`：原有 22 种场景，以及真实日志投影、合成模式切换、Pro 无五小时窗口、仅周窗口、仅余额、API-key 空额度/错误、未知套餐、按 codex ID 选窗口和 Cyber 长上下文，共 32 种场景的英文浅色/深色 PNG。`menu/{zh-Hans,zh-Hant,ja,ko}/` 各增加三种关键场景的双主题渲染，检查现有五种语言。
- `benchmark.json`：输入大小、冷扫描、无变化增量、追加、重启和重建耗时，以及进程峰值 RSS、缓存字节数和结果对比。
- `benchmark-copies.json`：2 万个累计样本分布在 8 个副本中的相同指标；包含缺失中间记录和完全相同的副本。

AppKit 检查收集 `Sources/CodexRateLimitsBar/` 中除 `main.swift` 外的全部实际实现文件，使用独立验证入口；`main.swift` 仅保留应用启动入口。Core 对象与模块只从 `swift build --show-bin-path` 返回的当前目录读取，兼容 Swift 6.4 Swift Build 的合并对象及旧 SwiftPM 的逐文件对象，不搜索其他可能过期的构建目录。验证入口不启动菜单栏、登录项或通知。自动检查共享快照的显示标签和状态是否传入视图，生成图像供排版检查；PNG 成功生成不等于已经自动判断所有像素的正确性。

`UsageRefreshControllerTests` 用假客户端、可控工作队列和时钟直接运行实际刷新控制器；工作完成与主线程应用结果可以分开推进，验证账户切换、迟到响应、睡眠/唤醒和退出时的丢弃，以及失败恢复和重建请求合并。通知测试接入真实 `QuotaMonitor` 和可控接收回调，检查失败重试、取消、去重及确认落盘，不调用系统通知中心。队列屏障用于等待完成回调，测试不依赖休眠或真实时间推进。系统通知能否实际送达仍属于人工验收范围。

大日志和副本测试对 tokens、API/credits 金额及全量/增量一致性作硬断言，缓存应小于 1 MiB、测试进程峰值 RSS 小于 256 MiB，以识别整文件驻留和逐事件历史落盘。副本对齐仅在重放期间持有累计样本，完全相同的轨迹只对齐一次；无变化时复用精简缓存。耗时只记录，不使用依赖机器速度的固定通过阈值。RSS 是整个测试进程的高水位，包含生成样例及测试框架开销。合成测试不能替代复杂真实会话的所有性能特征。

credits 语义回归由 `CreditAccountingTests` 覆盖纯写入、混合输入、缺失写入字段、矛盾分项、上下文边界及原始 v1 自定义卡。`ScannerEquivalenceTests.testCreditAccountingMigrationPreservesAPIAndWeeklyEvidence` 比较旧卡/新卡、v3 计算签名、跨进程恢复、重建和回滚，检查 tokens、API 金额、credits 未计价量、周分钟桶及官方样本，并确认无变化读取不重复写缓存。CLI/MCP 与新增两种菜单场景共享独立计算的用量样例。

`PricingPresentationTests` 验证原因摘要、API/credits 不重复合计、未记录模式、未来原因代码与旧显示快照兼容。CLI/MCP 对比全部日显示字段，周标签仅在有官方上下文的两个 status 入口比较；跨进程金额按 1e-12 消除求和顺序舍入差异，tokens、覆盖率和原因仍精确比较；新增四请求样例独立核对 1,000 tokens、90% API 覆盖和 40% credits 覆盖。UI 检查各悬停区域的详情、原因摘要宽度及配置/扫描错误的独立提示。语言通过子进程 `-AppleLanguages` 参数选择，不改动用户偏好；其他语言样例移除旧显示文字，检验从原始数据生成的兼容回退。

`PricingHealthTests` 检查遗漏模型/模式、合法自定义覆盖、别名解析和复核日期边界；`PricingReleaseTests` 使用手算金额覆盖全部 21 个 API、13 个 credits 模型和明确支持的模式。`verify_pricing.py` 验证默认路径、环境选择、候选卡不激活、无效卡回退及恢复，逐次核对目录文件哈希；沙箱另行禁止读取隔离账户和写入样例目录。打包检查也执行 `pricing --health`，确认不依赖构建目录。日期提醒不改价格、模型或缓存签名。官方网页调研与离线验收分开，来源、证据缺口及发布步骤见[价目表维护清单](pricing.md#release-maintenance-checklist)。

## 客户端与套餐契约样例（TODO-22）

TODO-24 另在 `verify_client_contracts.py` 构造纯合成旧模型写入样例：GPT-5.5/5.4 各两次混合读写请求，另有 GPT-6.1 Sol 无写入对照。每份日志有两个副本；去重后为 630,000 tokens、$1.606 API 等值、4.9 credits，credits 未计价 420,000 tokens。先写首条计数、再追加，比较 CLI/MCP、真实进程重启及重建；新增 `fixtures/contract-cache-writes.json` 数值产物，不增加 UI 场景。`verify_pricing.py` 还检查旧自定义卡仅两行 API 写入价不同，credits 无差异，候选文件保持原样。

TODO-25 的 Cyber/Daybreak Red 合成请求使用输入 272,001（cached 80K、write 20K）、输出 5K（含 reasoning 4K）。CLI/MCP 均应得到 277,001 tokens、$5.687525 API 等值及 277,001 credits 未计价 tokens，原因为 `unverifiedCacheWrite`；`cyber-long-context` 场景验证历史别名、金额和原因的双主题显示。单元回归另覆盖 272K 边界、纯读写、缺上下文、无写入长上下文的 credits 保护，以及旧卡升级、追加、重启、重建、回滚和日志恢复。价格健康集成确认显式自定义 272K 上限仍合法，只报告 Cyber 及其别名的 API 规则差异，不改写候选文件。

[client-contracts](../Tests/Fixtures/client-contracts/) 明确区分真实记录投影和合成验证数据：

| 文件 | 来源和用途 |
| --- | --- |
| `observed-rollouts.json` | 从本机近期日志提取五份最小投影，仅保留会话 ID/父子关系、来源版本、模型和前两次计数。ID/时间替换，计数保留；不含提示词、回复、路径、昵称、账户数据或凭据。 |
| `synthetic-modes.json` | 基于观察到的事件结构构造独立数值样例，涵盖 6.1 Sol Fast、Astra Ultrafast、模型切换、模式缺失、未知模型和模式；显式档位为合成输入，不是实际扣费证据。 |
| `protocol-evidence.json` | 已安装 CLI 0.160.0 离线导出的 app-server schema 字段投影，命令记在文件中；不能视为 rollout 的完整规范。 |
| `official-accounts.json` | 根据协议构造 Pro 无五小时窗口、仅周窗口、仅余额、API-key 空额度、未知套餐和 codex 映射响应；未采集真实账户接口。API-key 不可用错误另在集成脚本中模拟。 |

2026-10-06 调研的 35 份本机日志包含 0.154.0、0.159.x、0.160.0/0.160.1 的 `session_meta.cli_version`，观察到 6.1 Sol、Astra、Sol/Luna、模型切换及 `source.subagent.thread_spawn.parent_thread_id`。该版本是会话元数据，不能证明后续每个事件都由同一版本写入。五份最小投影包括关联父子记录，以及 0.160.1 元数据的子会话；Astra 投影保留原 0.154.0 来源声明。父子关系用于确认各自 ID，不把子会话当作父会话副本；只有相同会话的副本参与去重。这里只验证本地计数归属，不声称已对账服务端的整棵代理账单。

所查日志及 0.160.0 用量通知均未提供可确认的实际服务档位。应用继续按已记录字段估值，详情见[档位证据边界](pricing.md#recorded-mode-and-client-contract)。真实 Fast/Ultrafast 档位、每请求实际服务层和完整服务端父子计费关系仍待后续证据；合成样例不能填补这个缺口。

`ClientContractTests` 对比增量、实例重建和完整重放；`verify_client_contracts.py` 用实际 CLI/MCP 子进程加载同一个隔离磁盘缓存，对比 tokens、API/credits 金额、独立覆盖、缺失模式假设、未计价原因和日显示字段。先写前缀，再追加末条；无变化跨进程读取必须保持缓存文件字节不变。不同样例集使用不同 home/cache，不通过删除源日志或清缓存来证明复用。独立期望：真实投影去重后 245,087 tokens、$0.30183598、7.5458995 credits；合成切换 735,000 tokens、$0.9353、92.415 credits，其中 API/credits 分别有 105,000/210,000 tokens 未计价。套餐变化不改变本地日估值；无官方周窗口就不构造周估值。

同一批 JSON 进入 AppKit 检查与渲染。浮点金额仍只在跨进程数值比较时按 1e-12 规范化，显示文字必须精确相同；`EstimateFormattingTests` 另锁定 92.415 等半分边界的稳定舍入、真实价格差异、小额和极大有限值。

## 人工验收

修改视图时检查 `menu/` 产物中的截断、重叠、对比度和过期提示。安装后还需按[刷新恢复说明](refresh.md#验证)检查真实菜单跟踪、断网、睡眠唤醒及测试账户切换；这些系统事件不由默认验证自动触发，也不应将离屏截图视为真实事件验收通过。
