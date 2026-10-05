# ClaudeForFoundationModels（内置副本）

- 上游：https://github.com/anthropics/ClaudeForFoundationModels
- 版本：`0.2.2`（commit `b309728034c4181e20f56c5dc269f130a7e9866c`）
- 许可：Apache 2.0，见同目录 LICENSE

## 相对上游的改动

由 `tools/vendor-claude-fm.py` 机械生成，不要手改这里的源码——升级时重新跑脚本：

1. `Package.swift` 是本地版本：平台最低声明为 iOS 26，只保留两个库目标（去掉示例和测试）。
2. `Sources/ClaudeForFoundationModels/` 下每个顶层声明前加了
   `@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)`，被改动的文件顶部带修改说明。

原因：App 部署目标是 iOS 26.0，而上游声明 iOS 27 起且源码没有 @available，
直接作为 SPM 依赖会被 Xcode 拒绝。App 侧只在 `#available(iOS 27.0, *)` 分支里使用它。
