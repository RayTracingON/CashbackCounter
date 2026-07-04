import Foundation
import SwiftData

@Model
final class Point: Identifiable {
    var id: UUID = UUID()
    var bankName: String = ""
    var pointName: String = ""
    var pointValue: Double = 0.0
    var valueCurrencyCode: Region = Region.cn

    // 元信息
    var isActive: Bool = true
    var createdAt: Date = Date()
    var note: String = ""

    // 反向关系：哪些信用卡使用了这个积分计划
    // 删除 Point 时，卡的 pointProgram 设为 nil
    @Relationship(deleteRule: .nullify, inverse: \CreditCard.pointProgram)
    var cards: [CreditCard]?

    // 反向关系：关联的积分调整记录
    // 删除 Point 时，关联的调整记录一并删除
    @Relationship(deleteRule: .cascade, inverse: \PointAdjustment.pointProgram)
    var adjustments: [PointAdjustment]?


    init(
        bankName: String,
        pointName: String,
        pointValue: Double,
        valueCurrencyCode: Region,
        isActive: Bool = true,
        note: String = ""
    ) {
        self.id = UUID()
        self.bankName = bankName
        self.pointName = pointName
        self.pointValue = pointValue
        self.valueCurrencyCode = valueCurrencyCode
        self.isActive = isActive
        self.createdAt = Date()
        self.note = note
    }

    var displayName: String {
        "\(bankName) \(pointName)"
    }
}

struct PointSeed {
    let bankName: String
    let pointName: String
    let pointValue: Double
    let valueCurrencyCode: Region

    var templateKey: String {
        Point.templateKey(
            bankName: bankName,
            pointName: pointName,
            currencyCode: valueCurrencyCode
        )
    }

    func makeModel() -> Point {
        Point(
            bankName: bankName,
            pointName: pointName,
            pointValue: pointValue,
            valueCurrencyCode: valueCurrencyCode
        )
    }
}

extension Point {
    static let defaultSeeds: [PointSeed] = [
        PointSeed(bankName: "HSBC HK", pointName: "RC", pointValue: 1.25, valueCurrencyCode: .hk),
        PointSeed(bankName: "HSBC US", pointName: "Point", pointValue: 0.015, valueCurrencyCode: .us),
        PointSeed(bankName: "BEA HK", pointName: "Point", pointValue: 0.01, valueCurrencyCode: .hk),
        PointSeed(bankName: "CCB HK", pointName: "Point", pointValue: 0.006, valueCurrencyCode: .hk),
        PointSeed(bankName: "Chase", pointName: "UR", pointValue: 0.015, valueCurrencyCode: .us),
        PointSeed(bankName: "AMEX HK", pointName: "MR", pointValue: 0.0056, valueCurrencyCode: .hk),
        PointSeed(bankName: "AMEX US", pointName: "MR", pointValue: 0.016, valueCurrencyCode: .us),
        PointSeed(bankName: "Marriott", pointName: "Point", pointValue: 0.007, valueCurrencyCode: .us),
        PointSeed(bankName: "Hilton", pointName: "Point", pointValue: 0.004, valueCurrencyCode: .us),
        PointSeed(bankName: "Alaska", pointName: "ATMOS", pointValue: 0.016, valueCurrencyCode: .us),
        PointSeed(bankName: "IHG", pointName: "Point", pointValue: 0.005, valueCurrencyCode: .us),




        
    ]

    static func syncDefaultPoints(in context: ModelContext) throws {
            let descriptor = FetchDescriptor<Point>()
            let currentPoints = try context.fetch(descriptor)

            // ── 第 1 步：去重 ──
            // 按 templateKey 分组，如果同一个 key 下有多条记录，说明发生了重复
            // （覆盖安装后 iCloud 同步 + 本地种子插入会导致此情况）
            let grouped = Dictionary(grouping: currentPoints) { templateKey(for: $0) }

            var hasChanges = false
            var deduplicatedMap: [String: Point] = [:]

            for (key, points) in grouped {
                if points.count > 1 {
                    // 保留关联关系最多的那条（防止删除已被用户绑定到卡片/调整记录的 Point）
                    let sorted = points.sorted {
                        let aCount = ($0.cards?.count ?? 0) + ($0.adjustments?.count ?? 0)
                        let bCount = ($1.cards?.count ?? 0) + ($1.adjustments?.count ?? 0)
                        return aCount > bCount
                    }
                    let keeper = sorted[0]
                    deduplicatedMap[key] = keeper

                    // 将被删除的重复项上的关联关系迁移到保留项
                    for duplicate in sorted.dropFirst() {
                        // 迁移信用卡关联
                        if let cards = duplicate.cards {
                            for card in cards {
                                card.pointProgram = keeper
                            }
                        }
                        // 迁移积分调整记录关联
                        if let adjustments = duplicate.adjustments {
                            for adjustment in adjustments {
                                adjustment.pointProgram = keeper
                            }
                        }
                        context.delete(duplicate)
                        hasChanges = true
                    }
                } else if let point = points.first {
                    deduplicatedMap[key] = point
                }
            }

            // ── 第 2 步：同步种子数据 ──
            // 只补插缺失的种子，不覆盖已存在记录的 pointValue——
            // 用户可能手动修改过估值，每次启动强刷回默认值会丢失用户设置
            for seed in defaultSeeds where deduplicatedMap[seed.templateKey] == nil {
                context.insert(seed.makeModel())
                hasChanges = true
            }

            // ── 第 3 步：有实质性变更时才落盘 ──
            if hasChanges {
                if context.hasChanges {
                    try context.save()
                }
            }
        }

    fileprivate static func templateKey(for point: Point) -> String {
        templateKey(
            bankName: point.bankName,
            pointName: point.pointName,
            currencyCode: point.valueCurrencyCode
        )
    }

    fileprivate static func templateKey(bankName: String, pointName: String, currencyCode: Region) -> String {
        let parts = [bankName, pointName, currencyCode.currencyCode]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return parts.joined(separator: "|")
    }
}
