//
//  AddTransactionFromReceiptIntent.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 12/1/25.
//

import AppIntents
import CoreImage
import SwiftUI
import VisualIntelligence

/// 通过 Visual Intelligence 识别收据后，自动唤起应用并带着图片跳转到记账页。
struct AddTransactionFromReceiptIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Transaction from Receipt"

    /// 让 Intent 运行后直接拉起主应用。
    static var openAppWhenRun: Bool = true

    /// Visual Intelligence 提供的语义内容，包含标签与相机帧。
    @Parameter(title: "Receipt")
    var semanticContent: SemanticContentDescriptor

    @MainActor
    func perform() async throws -> some IntentResult {
        // 1. 确认标签确实表示“收据”。
        let labels = semanticContent.labels.map { $0.lowercased() }
        guard labels.contains(where: { $0.contains("receipt") || $0.contains("bill") }) else {
            return .result(dialog: IntentDialog("未识别到收据内容"))
        }

        // 2. 拿到像素数据，转成 UIImage。
        guard let pixelBuffer = semanticContent.pixelBuffer,
              let image = pixelBuffer.toUIImage(),
              let imageData = image.jpegData(compressionQuality: 0.7) else {
            return .result(dialog: IntentDialog("未获取到有效的收据图像"))
        }

        // 3. 把图片暂存到本地，等应用拉起后自动进入 AddTransactionView。
        ReceiptLaunchStore.shared.storePendingReceipt(data: imageData)

        return .result(dialog: IntentDialog("已识别到收据，正在打开应用填写账单"))
    }
}

private extension CVPixelBuffer {
    func toUIImage() -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: self)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
