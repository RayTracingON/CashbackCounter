# Cashback Counter 宣传视频（40s 竖屏）

用 [Remotion](https://www.remotion.dev)（React 写视频）做的 1080×1920 / 30fps / 40s 成片，面向小红书、抖音。
画面里的 App 界面都是模拟器的真实截图或录屏；银行同步页因为模拟器上没法用 Apple 登录，是照着 `BankSyncView` 的结构重画的。

## 分镜

| 时间 | 段落 | 文案 | 画面 |
|---|---|---|---|
| 0–4s | 钩子 | 刷完卡，账已经记好了 / 返现 · 积分 · 上限，自动算清 | 六张卡扇形飞入，Venture X 抬起，弹出「已自动记账 +$0.24」 |
| 4–13s | 01 快捷指令 | 收到扣款短信 / 自动记一笔 | 银行短信通知 → 快捷指令运行 → 账单页顶部插入 Blue Bottle Coffee，统计数字更新 |
| 13–21s | 02 美国银行同步 | 绑定一次银行 / 交易自己进来 | 银行同步页逐个开启 → 切到账单，交易一条条落进来；Plaid 安全连接、退款自动抵销、新交易推送 |
| 21–30s | 03 端侧 + 云端 AI | 拍张小票 / AI 秒填好 → 离线还是云端 / 你来选 | 小票扫描 → 识别结果卡；三种通道：端侧模型、Apple 私有云计算、自定义 API |
| 30–36s | 04 内置卡模板 | 40+ 热门信用卡 / 一键添加 | 模板库真实滚动录屏 + 两侧漂浮卡面 |
| 36–40s | 结尾 | Cashback Counter · 返现小助手 / 每一笔，都算得明明白白 | 图标、四项能力回顾、App Store 搜索引导 |

## 常用命令

```bash
npm install            # 首次
npm run studio         # 浏览器里逐帧预览、调时间轴
npm run render         # 输出 out/promo.mp4
npx remotion still Promo out/cover.png --frame=105   # 封面图
```

- 改文案：每段都在 `src/scenes/*.tsx` 的 `Headline` / `Chip` 里。
- 改节奏：`src/Promo.tsx` 的 `SCENES` 时长（总长 = Σ时长 − 5×12 帧转场）。
- 配色：`src/theme.ts`，取自 App 图标的墨绿 + 金色。
- **没有配乐**，建议发布时直接用平台曲库（版权最省心），或在剪映里叠加。转场大致落在 4s / 13s / 21s / 30s / 36s。

## 重拍素材

`public/screens/` 下的截图来自 iPhone 18 Pro Max 模拟器（简体中文、主货币 USD、状态栏 9:41）。模板库滚动录屏拆成了 `public/screens/tpl/` 的序列帧。演示数据由 `tools/DemoSeed.swift` 灌入，它**不在 App target 里**，要重拍时：

1. 把 `tools/DemoSeed.swift` 复制到 `CashbackCounter/`（文件系统同步组会自动加入 target）；
2. 在 `CashbackCounterApp.init()` 末尾加：
   ```swift
   #if DEBUG && targetEnvironment(simulator)
   DemoSeed.runIfRequested(in: container)
   #endif
   ```
3. 以 `-DemoSeed` 启动（会清空**模拟器**本地库再灌数据；模拟器上 CloudKit 本来就是关的）。加 `-DemoSkipLatest` 可得到「快捷指令记账前」的账单页；
4. `xcrun simctl status_bar <id> override --time 9:41 --batteryState discharging --batteryLevel 100` 后截图；
5. 拍完把这两处改动撤掉。

账单页动画依赖截图里量出来的像素坐标（`src/theme.ts` 的 `BILL`），如果 UI 布局变了需要重新量。

## 注意

- 银行同步是付费功能、仅支持美国机构；视频标题已写「美国银行同步」。
- 快捷指令结果横幅显示的是 `$6.75`，而当前代码里 `AddTransactionFromSMSIntent` 的提示写死了 `¥`，发布前最好先修掉，保持一致。
- Remotion 对个人和 ≤3 人的公司免费，超过需要购买公司授权。
