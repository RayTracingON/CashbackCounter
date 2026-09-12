# Cashback Counter · 功能说明与简介

> 面向使用者与新加入的开发者的一份总览：这个 App 是什么、能做什么、每个功能背后是怎么运作的。
> 内容基于当前源码整理（App Store 版本 2.4.1，最低系统要求 iOS 26.0）。

---

## 一、一句话简介

**Cashback Counter（返现小助手）** 是一款 SwiftUI + SwiftData 构建的 iOS 记账应用。
它和普通记账 App 的区别在于：**记账只是手段，算清"这一笔该拿多少返现／积分"才是目的**。

你把手里每张信用卡的规则（基础费率、类别加成、支付方式加成、境内外费率、封顶上限、结算周期）录进卡包，
之后无论是拍小票、粘贴银行短信、导入 PDF 结单，还是让银行交易自动同步进来，
App 都会用同一套费率引擎，把返现金额、积分数量、上限用量一并算好。

**三种记账入口，一套计算引擎：**

| 入口 | 形态 | 说明 |
|---|---|---|
| 手动 / 拍照 | 相机、相册、手输 | 端侧或云端大模型识别小票，自动填商户、金额、日期、类别、卡片 |
| 半自动 | 快捷指令、PDF 结单 | 短信解析、截屏记账、结单对账补漏 |
| 全自动 | Plaid 银行同步 | 交易自己进来，退款自动抵销（仅美国机构，付费功能） |

---

## 二、界面结构

App 采用五个底部标签页：

| 标签 | 页面 | 承担的事 |
|---|---|---|
| 📄 **账单** | `BillHomeView` | 交易流水、类别／收入／日期三向筛选、搜索、支出与返现统计条、趋势图入口、CSV+收据打包导入导出 |
| 💳 **卡包** | `CardListView` | 卡片列表（拟真卡面、长按拖动排序）、按卡的消费与返现汇总、模板库、新增／编辑卡片 |
| 📷 **拍一笔** | `CameraRecordView` | 自定义相机拍摄小票 → AI 识别 → 一键入账 |
| ⭐️ **积分** | `PointSystemView` | 积分计划库、当前积分与估值、近 6 个月积分变化、积分变动明细（获得／兑换／过期／转移／赠送／手动） |
| ⚙️ **设置** | `SettingView` | 外观语言、本币、默认卡片、通知、AI 模型选择、快捷指令教程、数据管理、账号与银行同步、关于 |

---

## 三、核心功能详解

### 3.1 返现／积分计算引擎（App 的心脏）

计算逻辑集中在 `CreditCard.calculateCappedCashback` 与 `calculateCappedPoints`。
**一笔消费的奖励由三部分相加**，且三部分各自独立封顶：

```
最终奖励 = min(基础费率奖励, 基础剩余额度)
         + min(类别加成奖励, 该类别剩余额度)
         + min(支付方式加成奖励, 该方式剩余额度)
```

* **基础费率走"双轨"**：本币轨道（`localBaseCap`）和外币轨道（`foreignBaseCap`）分别统计上限，
  由 `rewardTrack(for:)` 判定这笔消费落在哪条轨道上。
* **类别加成**按消费类别（餐饮／超市／出行／数码／二次元／订阅／其他）叠加，上限不分地区、只看类别。
* **支付方式加成**按 Apple Pay / QR Code / 线上 / 线下 / Pulse / GBA 叠加，独立上限。
* **结算周期**可选按月（`monthly`）或按年（`yearly`）；统计历史用量时会排除正在编辑的那一笔，避免自己算自己。
* **积分卡**走同一套上限逻辑，只是把金额换成积分数，再按积分计划的单点估值折算成发卡币种的等值金额。

### 3.2 双币卡支持

真实世界里"双币卡"有两种完全不同的玩法，App 用 `DualCurrencyMode` 区分：

| 模式 | 典型场景 | 行为 |
|---|---|---|
| `secondaryAsLocal`（并入本币上限 1:1） | 港式 HKD+CNY | 副币种地区的消费按 1:1 计入本币上限轨道 |
| `secondaryAsForeign`（独立外币上限） | 陆式 CNY+USD | 所有境外消费入账副币种，走独立的外币上限轨道 |

副币种消费还可以单独设 `secondaryRate` 覆盖该轨道的常规费率。
这块逻辑有专门的 `DualCurrencyCardTests`（388 行）覆盖。

### 3.3 智能识别记账

* **拍照识别**：`CameraRecordView` 用 AVFoundation 自定义相机，避免系统相册跳转的割裂感。
* **多模态优先**：iOS 27+ 且云端可用时，原图直传模型（`ReceiptParser.parseReceiptImage`），跳过本地 OCR。
* **OCR 文本管线兜底**：`OCRService` 用 Vision 做文本识别，并**按 y 坐标重建行结构**（`RecognizedRow`），
  保留小票的表格布局再交给模型——纯文本流会丢掉"金额和商品在同一行"这个关键信息。
* **地区自适应**：用户已选地区时按该地区的语言集精准识别；未选时多语言识别后由模型推断。
* **自动填充**：商户、金额、日期、消费类别，以及**根据小票上的卡号后四位自动选中对应信用卡**。
* **规则兜底**：模型漏抽金额／币种时，`OCRService.backfill` 用正则补齐。

三种 AI 后端可在设置页切换：

1. **本地模型** —— Apple Foundation Models 端侧运行，完全离线。
2. **Apple 私有云计算（PCC）** —— 端到端加密，Apple 与开发者均不可读；不可用时自动回退端侧。
3. **自定义 API** —— 用户自带的第三方模型（`ThirdPartyModel/`），支持三种协议格式：
   * OpenAI 兼容（事实标准，覆盖 DeepSeek / Kimi / 通义 / 智谱 / SiliconFlow / OpenRouter / Ollama / LM Studio / vLLM）
   * Anthropic Messages（结构化输出走强制工具调用）
   * Google Gemini generateContent（responseSchema 走 OpenAPI 3.0 子集）
   API Key 存 Keychain 而非 UserDefaults，且**退出登录不会清除**（它是设备级配置，不属于某个账号）。

### 3.4 快捷指令与自动化（App Intents）

`CashbackShortcutsProvider` 注册了两个可被 Siri / 操作按钮 / 自动化触发的意图：

* **`AddTransactionFromSMSIntent`** —— 粘贴或自动传入信用卡通知短信，解析后直接入账。
  配合「快捷指令 → 自动化 → 信息」可做到收到银行短信自动记账。
* **`AddTransactionFromScreenshotIntent`** —— 传入屏幕截图，OCR 识别后入账。
  配合 iPhone 操作按钮，在任意消费凭证页面长按即可一键记账。

两者都通过 `SharedModelContainer` 与主 App 共用同一个 `ModelContext`——
不另起 CloudKit 同步栈，写入后主界面 `@Query` 立即刷新。

### 3.5 PDF 结单分析与对账

`StatementParser`（1039 行）+ `ReconciliationEngine`：

1. 上传信用卡 PDF 结单，PDFKit 提取文本并解析出交易列表、总额、卡号后四位、卡名。
2. `ReconciliationEngine.compare` 把结单交易与 App 内已有记录做匹配：
   **金额差 < 0.01 且日期相差 ≤ 3 天**视为同一笔，且每条已有记录只能被匹配一次（避免一对多误判）。
3. 输出「已记录」和「App 中缺失」两组，缺失的可一键补录。

### 3.6 银行自动同步（Plaid，付费功能，仅美国）

这是目前投入最重的一块，`PlaidSyncService`（639 行）遵循三条硬性原则：

> 1. **只碰 `source == .plaid` 的记录** —— 去重、退款抵销、任何删除都绝不作用于用户手动记的账。
> 2. **管线幂等** —— 同一批数据跑两遍的结果必须和跑一遍一样。
> 3. **宁可少算不要多算** —— 分不清的情况一律走保守分支。

具体能力：

* **绑定流程**（`PlaidLinkService`）：link_token → Link 弹窗 → public_token → item_id → 账户列表 → 匹配卡片。
  按账户尾号（`mask`）自动匹配卡包里的卡；同尾号多张时返回 `.ambiguous` 让用户确认；匹配不到则不开启同步
  （没有费率规则就算不出奖励，同步进来只是一堆算不了返现的流水）。
* **生物识别关卡**（`BiometricGate`）：唤起 Plaid Link 前必须过 Face ID / Touch ID（可回落设备密码）。
  理由是会话 token 在 Keychain 里活 30 天，任何拿到已解锁手机的人否则都能直接绑一家银行进去。
* **同步节奏**：每个自然日第一次打开 App 时同步一次（用"今天同步过没"而非"距上次 N 小时"，因为前者对用户可解释）；
  银行同步页下拉可随时强制刷新。
* **首次全量 vs 增量**：首次最多回溯 730 天，被银行截断时递归二分窗口（最小 7 天）；
  之后转增量，并额外回看 7 天以覆盖 pending 转 posted 的延迟和银行晚报的交易，重叠部分由去重吸收。
* **数量对齐去重**（`insertWithCountAlignment`）：按「卡＋日期＋金额」对齐条数，
  而**不是**"存在即跳过"——同一天在同一家店买两杯一样的咖啡是两笔真实交易，不能被吞掉一笔。
* **退款自动抵销**：退款冲掉对应的原始消费，返现与上限用量跟着回冲；还款和转账不会被误判成退款。
* **分类映射**（`PlaidCategoryMapping`）：Plaid 的两级 PFC 分类映射到 App 的 `Category`，
  **优先看 detailed 而非 primary**（超市和餐厅的 primary 都是 FOOD_AND_DRINK），拿不准一律落 `.other`。
* **新交易推送**（`PushNotificationService`）：银行有新交易时推一条可见通知（只带银行名，不含金额与商户）。
  刻意不用静默推送——iOS 的 background push 是尽力而为，而用户对"通知"的预期是必达。
* **解绑**：支持解绑单张卡或整个 item；解绑会先在 Plaid 侧撤销授权再删本地记录。

### 3.7 多币种与汇率

* 支持地区／币种：🇨🇳 CNY、🇭🇰 HKD、🇺🇸 USD、🇯🇵 JPY、🇳🇿 NZD、🇹🇼 TWD、🇲🇴 MOP、🇬🇧 GBP、🇪🇺 EUR。
* `CurrencyService` 接 Frankfurter API 获取汇率，**按天缓存**（同一天且基准币种一致直接读本地缓存），
  网络不可用时回退缓存值。
* 每笔交易同时记录**原币金额**（`amount`）与**实际入账金额**（`billingAmount`）+ 入账币种，
  解决银行自己的汇率差导致对不上账的问题。
* 积分估值币种与发卡币种不同时（如 Amex HK 积分按 HKD 估值但卡是美国发的），会按汇率换算一次再计入。

### 3.8 卡片模板库

`CardTemplateManager` + `CardTemplates.json`：

* 内置 **35 个模板**，覆盖 15 家发卡机构：滙豐香港 / HSBC US、信銀國際、工銀亞洲、建行亞洲、東亞銀行、中銀香港、
  AMEX HK / AMEX US、Chase、Apple、中信银行、工商银行、农业银行、Ready 等，横跨中国大陆 / 香港 / 美国三个地区。
* **远程优先、本地兜底**：优先从 GitHub Raw 拉最新模板（5 秒超时），失败则读 App 内打包的 JSON。
* **规则回灌**：卡片记录 `templateKey`，模板更新后启动时自动把新费率同步回用户已添加的卡（`applyRules`），
  只写真正变化的字段。
* 仓库内附带一个 `tools/cardeditor` 网页版模板编辑器，方便贡献新卡模板。

### 3.9 数据完整性：去重与迁移

CloudKit 在 App 更新触发 schema 迁移后会重新导入记录，制造重复数据。App 对此有两套针对性处理：

* **卡片去重**：每次启动都跑。按「银行｜卡种｜尾号」分组，尾号为空的一律跳过（无法可靠判定是否同一张卡）。
  保留交易最多、有卡面图的那张作 master，**并把重复卡的交易和银行绑定关系全部转移过去**再删除
  ——银行绑定若不转移，会因为 `.nullify` 让那张卡从此静默停止同步，且界面上毫无报错。
* **交易去重**：只在必要时跑（去重规则版本提升 / App 构建号变化 / 数据库重建）。
  **只按 `Transaction.dedupeID`（建档时生成一次的 UUID）分组，绝不按内容分组**——
  按 (商户, 日期, 金额) 做指纹会把"同一天买的两杯一样的咖啡"永久删掉一杯，而用户根本发现不了。
  旧数据 dedupeID 为空时就地补一个新 UUID，代价是此刻已存在的重复合并不掉。
  这个取舍是刻意的：**多一笔用户看得见也能自己删，凭空少一笔看不见也救不回来。**

### 3.10 统计、导出与备份

* **趋势分析**（`TrendAnalysisView`）：支出与返现的时间趋势图，可按月／年查看。
* **按卡汇总**：每张卡的消费额、返现额、上限用量。
* **收入单**（`Income`）：可为某笔支出关联收入记录（含平台、是否已收到），用于计算"实际利润"
  ——典型场景是代购、报销、羊毛党的成本收益核算。
* **完整备份**：导出为 ZIP（`Transactions.csv` + `Receipts/` 收据原图），可原样导入还原。
* **卡片单独导出**：`CardCSVHelper` 导出 31 列的卡片规则 CSV（含双币卡三列），带 BOM 头保证 Excel 中文不乱码。

### 3.11 其他

* **还款提醒**：按卡设置还款日，每月当天 9:00 本地通知。
  通知 identifier 由银行｜卡种｜尾号生成，**刻意不用 `hashValue`**——Swift 哈希种子每次启动都变，会导致重启后取消不掉旧通知。
* **iCloud 同步**：SwiftData + CloudKit，登录相同 Apple ID 的设备间自动同步。
* **多语言**：简体中文（源语言）、繁體中文、English，共 558 条字符串。
* **外观**：跟随系统／浅色／深色，语言可在 App 内单独切换而不改系统语言。
* **引导页**（`OnboardingView`，1405 行）：首次启动的功能介绍与初始配置。

---

## 四、隐私模型

App 的隐私边界分成清晰的两半：

**不启用银行同步时，App 不与任何自建服务器通信。**
手动记账的数据只存在本地或用户自己的 iCloud（SwiftData + CloudKit），不上传、不收集。

**启用银行同步后：**

| 关注点 | 实际情况 |
|---|---|
| 交易数据 | 后端每次向 Plaid 现取现回，响应发出后即不存在，服务器上没有任何流水副本 |
| 卡号 | Plaid 的任何产品都不提供完整卡号（PCI DSS 管辖范围），App 能拿到的最详细信息是账户尾号 |
| 银行凭据 | Plaid access_token 以 AES-256-GCM 加密入库，密钥不在数据库也不在代码里 |
| 会话凭据 | 存 Keychain（`kSecAttrAccessibleAfterFirstUnlock`），不用 UserDefaults——后者只是沙盒里一个明文 plist |
| 退出 | 解绑银行会先在 Plaid 侧撤销授权再删本地记录；删除账号会一并解绑所有银行并撤销 Apple 登录授权。已导入的交易保留在设备上 |

**登录不是使用 App 的前提。** 手动记账、卡包、费率引擎一行网络请求都不需要，
只有进入「银行同步」才要求 Sign in with Apple——这既是产品判断，也符合 App Store 审核指南 5.1.1(i)。

---

## 五、订阅

免费使用全部手动记账、卡包、AI 识别、结单分析、积分、导出功能。
**Premium 仅解锁银行自动同步**（月付 $1.99 / 年付 $19.99，均含 1 周免费试用）。

会员判定（`SubscriptionManager.isPremium`）取**本地 StoreKit 权益 ∪ 后端认定**：

* 只认本地不行——推广代码兑换、家庭共享、运营侧手工开通这些合法付费方式不会出现在本机的 `currentEntitlements` 里。
* 只认后端也不行——后端不可达时用户会突然失去已付费的功能。
* App 会把 **Apple 签名的交易凭据（JWS）** 上报给后端，后端用 Apple 根证书验签。
  这是后端敢据此放行的原因（伪造需要 Apple 私钥），也是必要的：Plaid 按活跃 item 每月计费，
  后端不知道订阅状态的话，用户过期甚至删了 App，item 仍在烧钱。

---

## 六、技术栈与工程结构

| 层 | 技术 |
|---|---|
| UI | SwiftUI（TabView / Charts / 自定义卡面渲染） |
| 数据 | SwiftData + CloudKit，`@Attribute(.externalStorage)` 存收据与卡面图 |
| AI | Apple Foundation Models（端侧 + Private Cloud Compute）、`@Generable` 枚举直接参与结构化输出 |
| 视觉 | Vision（OCR + 行结构重建）、AVFoundation（自定义相机）、PDFKit（结单） |
| 系统集成 | App Intents、UserNotifications、APNs、LocalAuthentication、StoreKit 2、AuthenticationServices、Security(Keychain) |
| 银行数据 | Plaid LinkKit（仅美国机构） |
| 后端 | Spring Boot + PostgreSQL，部署于 Azure App Service |
| 三方库 | ZIPFoundation |

**源码规模**：约 25,700 行 Swift（不含测试），15 个测试文件、212 个测试用例，覆盖费率计算、双币卡、
去重、Plaid 账户选择与奖励计算、分类映射、结单解析、积分操作、CloudKit schema 兼容性、第三方模型适配器等。

**目录组织**（`CashbackCounter/`）：

```
Models/         SwiftData 模型与领域枚举（CreditCard 内含费率引擎）
Repositories/   数据访问封装（Card / Transaction / Income / Point）
ViewModels/     页面状态与业务编排
Views/          页面级 SwiftUI 视图
Components/     可复用组件与无状态服务（OCR、解析、CSV、汇率、通知、去重）
Services/       有状态的单例服务（Auth、Plaid、订阅、推送、Keychain、第三方模型）
```

架构上是 MVVM + Repository：视图不直接碰 `ModelContext`，
跨页面共享状态走 `@Observable` 单例（`AuthService.shared`、`SubscriptionManager.shared` 等），
每类状态**只有一个判断出口**（是否登录只看 `AuthService.isSignedIn`，是否会员只看 `SubscriptionManager.isPremium`）。

---

## 七、已知限制

* 不区分卡组织（Visa / Mastercard / AmEx），无法表达"仅限某卡组织"的活动费率。
* 银行同步仅覆盖美国金融机构——Plaid 不支持中国大陆、香港等地。
* 同步进来的交易固定按「美国」计算消费地费率。
* 通过第三方钱包（AlipayHK、PayPal 等）的支付会被归类为「其他消费」，因为银行数据无法反映真实消费品类。
* 大量数据下的性能表现尚未充分验证（上限统计目前是每笔交易做一次同周期全量扫描）。
* 云端多模态识别需要 iOS 27+，且依赖 FoundationModels 的 beta 符号可用性（代码里有 dlsym 运行时探测与回退）。

---

## 八、路线图

**已完成**：CSV 导出 · 按卡消费返现表 · 类原生 Apple Pay 界面 · 收入单与利润核算 · 多币种 ·
多币种返现规则 · 返现上限统计 · TestFlight / App Store 上架 · 三语本地化 · 自定义 API 模型

**进行中**：银行账户自动同步（Plaid，仅美国）

**计划中**：支持更多国家和地区的银行 · 区分卡组织

---

*本文档由源码整理生成，如与实际行为不符，以代码为准。*
