# BTC/USDT 三账户动态再平衡系统

Flutter 3.44.9 / Dart 3.12.2。当前完成 **Phase 1–12：Paper 全链路、恢复对账及个人设备本地 Live 适配层**。

## 当前状态

- BTCUSDT 使用 Binance `24hr ticker` WebSocket，60 秒使用 REST 校准。
- WebSocket 断线采用有限指数退避重连，并向 UI 暴露断线状态。
- 三账户分别从系统 Keychain/Keystore 读取 API 凭据，并在设备本地签名后直连 Binance；未配置完整凭据时 Dashboard 使用明确标识的演示快照。
- 运行模式默认 `PAPER`。
- 自动入金、自动再平衡、利润提取默认全部关闭。
- Dashboard 默认只有只读连接；LIVE 入口保持锁定。底层真实订单/划转执行器已实现数据库优先的幂等保护，但必须通过 Paper 验证和安全门后才能接入自动运行。
- 金额和比例的领域计算使用 `Decimal`，数据库以十进制字符串保存金额。
- 三账户估值与 BTC/USDT 权重统一通过 `PortfolioManager` 计算，权重精度为 18 位。
- 账户1通过 `FundingManager` 根据账户2现有仓位计算 BTC 购买额，不机械按新增资金的 50% 买入。
- `BacktestEngine` 与未来实盘共用 `RebalanceEngine`，支持手续费、滑点、冷却期、资产/权重曲线、月/年收益、CAGR 与最大回撤。
- `PaperTradingEngine` 使用真实市场状态、本地模拟成交；部分成交、冷却期、最小订单、断线和陈旧行情保护均已启用。
- `Account2StrategyRunner` 将行情更新与策略检查隔离，默认按配置周期检查并输出完整运行状态事件。
- `PaperRuntimeCoordinator` 已接入应用生命周期；只有 PAPER 与自动再平衡同时开启才运行，并将策略事件、订单、成交与手续费持久化。
- `PaperFundingExecutor` 模拟账户1购买与 BTC/USDT 双资产划转，订单及 Transfer ID 独立，并以外部入金事务 ID 保证幂等。
- `PerformanceManager` 将外部资金、内部划转、利润提款和手续费从 Trading PnL 中正确拆分；High Water Mark 支持资金流调整、利润结晶及数据库恢复。
- `ProfitManager` 只接受 FILLED SELL，并同时执行20%比例、可用USDT、SafeTransferLimit和提款后BTC权重不高于58%的限制。
- Paper SELL 成交后的合格利润会自动写入账户2→账户3划转、利润记录与新的 High Water Mark；停机前会排空最后一笔异步流水。
- `RecoveryCoordinator` 在启动时恢复未完成订单和HWM，并核对三账户、远端订单、连接状态及价格新鲜度；任何不一致都会阻止交易。
- 系统参数、订单/成交/划转/利润/日志查询、Binance 历史日线回测和资产曲线均已提供页面入口。
- LIVE 下单前读取 Binance 交易对过滤器，使用 Decimal 按步长向下舍入，并校验最小数量、最大数量与最小名义金额。

## 数据库

SQLite schema v1 包含：`accounts`、`account_snapshots`、`orders`、`trades`、
`transfers`、`deposits`、`withdrawals`、`strategy_events`、`strategy_config`、
`portfolio_snapshots`、`profit_withdrawals`、`high_water_marks`、`system_logs`。

订单和划转表均预留唯一幂等键；账户间流水与交易流水独立保存，为后续正确区分
外部资金、内部划转、交易收益、手续费和利润提取提供基础。

## 运行与验证

```bash
fvm flutter run
fvm flutter analyze
fvm flutter test
```

## 本机凭据与安全边界

本项目按个人自用、无后端模式运行。API Key/Secret 只写入系统 Keychain/Keystore，
不写入源码、普通 SQLite、日志或 Git。私有请求在设备本地使用 HMAC-SHA256 签名。

建议为 API Key 启用固定 IP 白名单、只开启所需的现货交易/内部划转权限，并始终关闭
链上提现权限。Root、越狱、调试注入或设备失窃仍可能导致本地 Secret 泄露。

Binance 返回 `-1007` 或网络超时时，系统只按 `clientOrderId` 查询订单状态，禁止直接
重复提交。无法确认时进入未知状态并停止交易。

私有账户余额由客户端分别使用三套本机安全凭据直读，不依赖后端。凭据页可逐账户检查连接及 API 权限。

LIVE 默认锁定，需要本机凭据、Paper 验证记录、权限检查、IP 限制及明确确认后才能解锁。
