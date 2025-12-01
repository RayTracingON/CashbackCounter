//
//  ReceiptLaunchStore.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 12/1/25.
//

import Foundation
import UIKit

/// 简单的本地缓存，用于在 Intent 与主应用之间传递收据图片。
final class ReceiptLaunchStore {
    static let shared = ReceiptLaunchStore()

    private let pendingReceiptKey = "pending_receipt_image"

    private init() {}

    /// 存储待处理的收据图片数据。
    func storePendingReceipt(data: Data) {
        UserDefaults.standard.set(data, forKey: pendingReceiptKey)
    }

    /// 获取并消费待处理的收据图片。
    func consumePendingReceipt() -> UIImage? {
        guard let data = UserDefaults.standard.data(forKey: pendingReceiptKey) else { return nil }
        UserDefaults.standard.removeObject(forKey: pendingReceiptKey)
        return UIImage(data: data)
    }
}
