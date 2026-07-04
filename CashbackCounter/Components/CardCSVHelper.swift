import Foundation
import SwiftUI
import SwiftData

struct CardCSVHelper {
    
    // 👇 1. 修改表头：末尾增加双币卡三列
    static let header = "银行名称,卡种名称,尾号,颜色1(Hex),颜色2(Hex),地区(Code),本币返现率(%),外币返现率(%),本币上限,外币上限,餐饮加成(%),超市加成(%),出行加成(%),数码加成(%),其他加成(%),餐饮上限,超市上限,出行上限,数码上限,其他上限,上限周期(monthly/yearly),还款日,支付方式加成(代码:rate),支付方式上限(代码:cap),奖励类型,积分名称,积分银行,备注,副币种地区,双币模式,副币费率(%)"
    
    // MARK: - 导出逻辑 (生成字符串)
    static func generateCSV(from cards: [CreditCard]) -> String {
        // \u{FEFF} 是 BOM 头，确保 Excel 打开中文不乱码
        var csvString = "\u{FEFF}" + header + "\n"
        
        for card in cards {
            // 1. 基础信息
            let bank = card.bankName.replacingOccurrences(of: ",", with: "，")
            let type = card.type.replacingOccurrences(of: ",", with: "，")
            let endNum = card.endNum
            
            // 2. 颜色
            let c1 = card.colorHexes.first ?? "0000FF"
            let c2 = card.colorHexes.last ?? "000000"
            
            // 3. 地区 & 基础费率
            let region = card.issueRegion.rawValue
            let defRate = String(format: "%.2f", card.defaultRate * 100)
            let forRate = card.foreignCurrencyRate != nil ? String(format: "%.2f", card.foreignCurrencyRate! * 100) : ""
            let locCap = card.localBaseCap > 0 ? String(format: "%.0f", card.localBaseCap) : ""
            let forCap = card.foreignBaseCap > 0 ? String(format: "%.0f", card.foreignBaseCap) : ""
            
            // 4. 类别加成
            let diningRate = fmtRate(card.specialRates[.dining])
            let groceryRate = fmtRate(card.specialRates[.grocery])
            let travelRate = fmtRate(card.specialRates[.travel])
            let digitalRate = fmtRate(card.specialRates[.digital])
            let otherRate = fmtRate(card.specialRates[.other])
            
            // 5. 类别上限
            let diningCap = fmtCap(card.categoryCaps[.dining])
            let groceryCap = fmtCap(card.categoryCaps[.grocery])
            let travelCap = fmtCap(card.categoryCaps[.travel])
            let digitalCap = fmtCap(card.categoryCaps[.digital])
            let otherCap = fmtCap(card.categoryCaps[.other])
            
            // 6. 杂项
            let rDay = card.repaymentDay > 0 ? String(card.repaymentDay) : ""
            let capPeriodStr: String
            switch card.capPeriod {
            case .monthly: capPeriodStr = "monthly"
            case .yearly:  capPeriodStr = "yearly"
            }
            
            // 👇 7. 新增：序列化支付方式字典 (格式: applePay:3.0|online:2.0)
            // 费率需要 * 100 变成百分比
            let pmRatesStr = card.paymentMethodRates.map {
                "\($0.key.rawValue):\(String(format: "%.2f", $0.value * 100))"
            }.joined(separator: "|")
            
            // 上限直接存金额
            let pmCapsStr = card.paymentCaps.map {
                "\($0.key.rawValue):\(String(format: "%.0f", $0.value))"
            }.joined(separator: "|")
            
            let rewardTypeStr = card.rewardType.rawValue
            let pointName = card.pointProgram?.pointName ?? ""
            let pointBank = card.pointProgram?.bankName ?? ""

            // 👇 新增：备注
            let memoStr = card.memo.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: ",", with: "，")

            // 双币卡字段
            let secRegionStr = card.secondaryRegion?.rawValue ?? ""
            let dualModeStr = card.secondaryRegion != nil ? card.dualCurrencyMode.rawValue : ""
            let secRateStr = card.secondaryRate != nil ? String(format: "%.2f", card.secondaryRate! * 100) : ""

            let row = "\(bank),\(type),\(endNum),\(c1),\(c2),\(region),\(defRate),\(forRate),\(locCap),\(forCap),\(diningRate),\(groceryRate),\(travelRate),\(digitalRate),\(otherRate),\(diningCap),\(groceryCap),\(travelCap),\(digitalCap),\(otherCap),\(capPeriodStr),\(rDay),\(pmRatesStr),\(pmCapsStr),\(rewardTypeStr),\(pointName),\(pointBank),\(memoStr),\(secRegionStr),\(dualModeStr),\(secRateStr)\n"
            csvString.append(row)
        }
        return csvString
    }
    
    // MARK: - 导入逻辑 (解析字符串)
    static func parseCSV(content: String, into context: ModelContext) throws {
        let rows = content.components(separatedBy: .newlines)
        let templates = CardTemplateManager.shared.templates
        let templateMap = Dictionary(templates.map { ($0.templateKey, $0) }, uniquingKeysWith: { first, _ in first })
        let points = try context.fetch(FetchDescriptor<Point>())
        var pointMap: [String: Point] = Dictionary(points.map { (pointKey(for: $0), $0) }, uniquingKeysWith: { first, _ in first })
        let templatePointMap = Dictionary(points.map {
            (CardTemplate.pointTemplateKey(bankName: $0.bankName, pointName: $0.pointName, currencyCode: $0.valueCurrencyCode), $0)
        }, uniquingKeysWith: { first, _ in first })

        let headerRow = rows.first ?? ""
        let hasMemoColumn = headerRow.contains("备注")

        // 双币卡列按表头定位 (旧版 CSV 没有这些列)
        let headerColumns = headerRow.replacingOccurrences(of: "\u{FEFF}", with: "").components(separatedBy: ",")
        let secRegionIdx = headerColumns.firstIndex { $0.contains("副币种地区") }
        let dualModeIdx = headerColumns.firstIndex { $0.contains("双币模式") }
        let secRateIdx = headerColumns.firstIndex { $0.contains("副币费率") }
        let hasDualColumns = secRegionIdx != nil


        for (index, row) in rows.enumerated() {
            if index == 0 || row.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            
            let columns = row.components(separatedBy: ",")
            if columns.count < 21 { continue } // 至少要能读到还款日之前的字段
        
            // 解析基础字段...
            let bankName = columns[0]
            let type = columns[1]
            let endNum = columns[2]
            let c1 = columns[3]
            let c2 = columns[4]
            let regionRaw = columns[5]
            let region = Region.allCases.first(where: { $0.rawValue == regionRaw }) ?? .cn
            
            let defRate = (Double(columns[6]) ?? 0) / 100.0
            let forRateStr = columns[7]
            let forRate = forRateStr.isEmpty ? nil : (Double(forRateStr) ?? 0) / 100.0
            let locCap = Double(columns[8]) ?? 0
            let forCap = Double(columns[9]) ?? 0
            
            // 解析类别加成
            var specialRates: [Category: Double] = [:]
            if let r = Double(columns[10]), r > 0 { specialRates[.dining] = r / 100.0 }
            if let r = Double(columns[11]), r > 0 { specialRates[.grocery] = r / 100.0 }
            if let r = Double(columns[12]), r > 0 { specialRates[.travel] = r / 100.0 }
            if let r = Double(columns[13]), r > 0 { specialRates[.digital] = r / 100.0 }
            if let r = Double(columns[14]), r > 0 { specialRates[.other] = r / 100.0 }
            
            // 解析类别上限
            var categoryCaps: [Category: Double] = [:]
            if let c = Double(columns[15]), c > 0 { categoryCaps[.dining] = c }
            if let c = Double(columns[16]), c > 0 { categoryCaps[.grocery] = c }
            if let c = Double(columns[17]), c > 0 { categoryCaps[.travel] = c }
            if let c = Double(columns[18]), c > 0 { categoryCaps[.digital] = c }
            if let c = Double(columns[19]), c > 0 { categoryCaps[.other] = c }
            
            // 处理上限周期和还款日
            let capPeriod: CapPeriod
            let rDay: Int
            
            // 先处理这两个旧字段，确保索引对其
            if columns.count >= 22 {
                let capStr = columns[20].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                switch capStr {
                case "monthly", "month", "m", "按月": capPeriod = .monthly
                case "yearly", "year", "y", "按年": capPeriod = .yearly
                default: capPeriod = .yearly
                }
                rDay = Int(columns[21]) ?? 0
            } else {
                capPeriod = .yearly
                rDay = Int(columns[20]) ?? 0
            }
            
            // 👇 新增：解析支付方式字典
            var pmRates: [PaymentMethod: Double] = [:]
            var pmCaps: [PaymentMethod: Double] = [:]
            
            // 只有当列数足够时才解析 (兼容旧版 CSV)
            if columns.count >= 24 {
                // 1. 解析加成 (Index 22)
                let rateStr = columns[22]
                pmRates = parseDictionaryString(rateStr, isRate: true)
                
                // 2. 解析上限 (Index 23)
                let capStr = columns[23]
                pmCaps = parseDictionaryString(capStr, isRate: false)
            }

            var rewardType: RewardType = .cashback
            var pointProgram: Point? = nil
            var memo: String = ""
            
            if hasMemoColumn && columns.count > 27 {
                memo = columns[27].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            if columns.count >= 25 {
                let rewardRaw = columns[24].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if rewardRaw == RewardType.points.rawValue || rewardRaw == "积分" {
                    rewardType = .points
                }
            }
            
            // 双币卡字段
            var secondaryRegion: Region? = nil
            var dualMode: DualCurrencyMode = .secondaryAsLocal
            var secondaryRate: Double? = nil
            if let i = secRegionIdx, columns.count > i {
                let raw = columns[i].trimmingCharacters(in: .whitespacesAndNewlines)
                secondaryRegion = Region.allCases.first { $0.rawValue == raw }
            }
            if let i = dualModeIdx, columns.count > i {
                let raw = columns[i].trimmingCharacters(in: .whitespacesAndNewlines)
                if let mode = DualCurrencyMode(rawValue: raw) {
                    dualMode = mode
                } else if raw.lowercased().contains("foreign") {
                    dualMode = .secondaryAsForeign
                }
            }
            if let i = secRateIdx, columns.count > i, let r = Double(columns[i]), r > 0 {
                secondaryRate = r / 100.0
            }

            // 旧版无双币列的 CSV 才走这段积分解析：新版 CSV 的 28+ 列是双币字段，会被误读成积分数据
            if rewardType == .points, !hasDualColumns, columns.count >= 29 {
                let pointName = columns[25].trimmingCharacters(in: .whitespacesAndNewlines)
                let pointBank = columns[26].trimmingCharacters(in: .whitespacesAndNewlines)
                let pointValue = Double(columns[27]) ?? 0
                let pointCurrencyIndex = columns.count > 29 ? 29 : 28
                let pointCurrency = columns[pointCurrencyIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                
                if !pointName.isEmpty, !pointCurrency.isEmpty {
                    let pointRegion = Self.region(from: pointCurrency)
                    let key = pointKey(
                        bankName: pointBank,
                        pointName: pointName,
                        currencyCode: pointRegion.currencyCode,
                        pointValue: pointValue
                    )
                    if let existing = pointMap[key] {
                        pointProgram = existing
                    } else if pointValue > 0 {
                        let newPoint = Point(
                            bankName: pointBank,
                            pointName: pointName,
                            pointValue: pointValue,
                            valueCurrencyCode: pointRegion
                        )
                        context.insert(newPoint)
                        pointMap[key] = newPoint
                        pointProgram = newPoint
                    }
                }
            }
            
            let newCard = CreditCard(
                bankName: bankName, type: type, endNum: endNum, colorHexes: [c1, c2],
                defaultRate: defRate, specialRates: specialRates, issueRegion: region,
                foreignCurrencyRate: forRate, localBaseCap: locCap, foreignBaseCap: forCap,
                categoryCaps: categoryCaps, capPeriod: capPeriod, repaymentDay: rDay,
                memo: memo, // 👈 新增：写入备注
                // 👇 传入新解析的字典
                paymentMethodRates: pmRates,
                paymentCaps: pmCaps,
                rewardType: rewardType,
                pointProgram: pointProgram,
                secondaryRegion: secondaryRegion,
                dualCurrencyMode: dualMode,
                secondaryRate: secondaryRate
            )

            // 如果有模板，应用模板规则 (注意：这可能会覆盖 CSV 里的费率设定，取决于你的设计)
            // 通常导入备份是为了恢复数据，所以这里是否应用模板看你需求。
            // 现有逻辑是“如果匹配到模板，就用模板覆盖”，这保留了动态更新的能力。
            let templateKey = CardTemplate.templateKey(bankName: bankName, type: type)
            if let template = templateMap[templateKey] {
                template.applyRules(to: newCard, pointMap: templatePointMap)
            }

            context.insert(newCard)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationManager.shared.scheduleNotification(for: newCard)
            }
        }
    }
    
    // MARK: - 辅助函数
    
    private static func fmtRate(_ val: Double?) -> String {
        guard let v = val else { return "" }
        return String(format: "%.2f", v * 100)
    }
    private static func fmtCap(_ val: Double?) -> String {
        guard let v = val, v > 0 else { return "" }
        return String(format: "%.0f", v)
    }
    
    // 👇 解析 "key:value|key:value" 格式字符串
    private static func parseDictionaryString(_ str: String, isRate: Bool) -> [PaymentMethod: Double] {
        var result: [PaymentMethod: Double] = [:]
        let items = str.components(separatedBy: "|")
        for item in items {
            let parts = item.components(separatedBy: ":")
            if parts.count == 2 {
                let keyStr = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let valStr = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                
                if let key = PaymentMethod(rawValue: keyStr), let val = Double(valStr) {
                    // 如果是费率，CSV里存的是 3.0 (3%)，需转回 0.03
                    result[key] = isRate ? (val / 100.0) : val
                }
            }
        }
        return result
    }

    private static func pointKey(
        bankName: String,
        pointName: String,
        currencyCode: String,
        pointValue: Double
    ) -> String {
        let valueKey = String(format: "%.8f", pointValue)
        return "\(bankName)|\(pointName)|\(currencyCode)|\(valueKey)"
    }

    private static func pointKey(for point: Point) -> String {
        pointKey(
            bankName: point.bankName,
            pointName: point.pointName,
            currencyCode: point.valueCurrencyCode.currencyCode,
            pointValue: point.pointValue
        )
    }

    private static func region(from currencyCode: String) -> Region {
        let normalized = currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let match = Region.allCases.first(where: { $0.currencyCode.uppercased() == normalized }) {
            return match
        }
        return .other
    }
}

// 核心扩展保持不变
extension Array where Element == CreditCard {
    func exportCSVFile() -> URL? {
        let csvString = CardCSVHelper.generateCSV(from: self)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let dateString = formatter.string(from: Date())
        let fileName = "Cards_Backup_\(dateString).csv"
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        do {
            try csvString.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            print("卡片导出失败: \(error)")
            return nil
        }
    }
}
