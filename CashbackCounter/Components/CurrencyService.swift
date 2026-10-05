import Foundation

// 1. 定义 API 响应结构 (适配动态币种键)
struct FrankfurterLatestResponse: Decodable {
    let date: String
    let base: String
    let rates: [String: Double]

    private struct DynamicKey: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)

        let dateKey = DynamicKey(stringValue: "date")!
        date = try container.decode(String.self, forKey: dateKey)

        guard let baseKey = container.allKeys.first(where: { $0.stringValue != "date" }) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: container.codingPath,
                      debugDescription: "Missing dynamic currency key")
            )
        }

        base = baseKey.stringValue
        rates = try container.decode([String: Double].self, forKey: baseKey)
    }
}

struct CachedRates: Codable {
    let base: String
    let rates: [String: Double]
}

struct CurrencyService {

    // --- 缓存配置 ---
    private static let kRatesKey = AppConfig.UserDefaultsKey.cachedExchangeRates // 存汇率数据的 Key
    private static let kDateKey = AppConfig.UserDefaultsKey.lastFetchDate        // 存上次更新时间的 Key
    private static let kBaseKey = AppConfig.UserDefaultsKey.lastRatesBase        // 存上次汇率基准币种
    
    // --- 🚀 智能入口：获取汇率 ---
    // View 层只调用这个方法，不需要关心内部逻辑
    static func getRates(base: String = "CNY") async -> [String: Double] {
        // 1. 检查：今天是不是已经更新过了？并且基准币种一致？
        if
            let lastDate = UserDefaults.standard.object(forKey: kDateKey) as? Date,
            let lastBase = UserDefaults.standard.string(forKey: kBaseKey),
            lastBase == base,
            Calendar.current.isDateInToday(lastDate)
        {
            // 如果最后更新时间是“今天”，并且基准币种一致，直接读缓存
            if let cachedRates = loadLocalRates() {
                print("✅ 汇率无需更新，使用本地缓存 (\(base))")
                return cachedRates.rates
            }
        }

        print("🌍 正在联网更新汇率 (base: \(base))...")
        do {
            let rates = try await fetchRemoteRates(base: base)
            let normalized = normalizedRates(rates)
            // 下载成功后，立刻存入本地
            saveRatesLocally(normalized, base: base)
            return normalized
        } catch {
            print("❌ \(AppError.networkFailure(underlying: error).localizedDescription)")
            if let cached = loadLocalRates(), cached.base.caseInsensitiveCompare(base) == .orderedSame {
                return cached.rates
            }
            return [base: 1.0]
        }
    }

    // --- 内部方法：联网下载 (私有) ---
    private static func fetchRemoteRates(base: String) async throws -> [String: Double] {
        let urlString = "\(AppConfig.currencyAPIBaseURL)\(base.lowercased()).json"
        guard let url = URL(string: urlString) else { return [:] }

        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(FrankfurterLatestResponse.self, from: data)
        return response.rates
    }

    // --- 内部方法：存入 UserDefaults ---
    private static func saveRatesLocally(_ rates: [String: Double], base: String) {
        let normalized = normalizedRates(rates)
        // 1. 存汇率 + 基准币种
        let cached = CachedRates(base: base, rates: normalized)
        if let data = try? JSONEncoder().encode(cached) {
            UserDefaults.standard.set(data, forKey: kRatesKey)
        }
        // 2. 存时间 (存当前时间)
        UserDefaults.standard.set(Date(), forKey: kDateKey)
        // 3. 存当前基准币种
        UserDefaults.standard.set(base, forKey: kBaseKey)
    }

    // --- 内部方法：读取 UserDefaults ---
    private static func loadLocalRates() -> CachedRates? {
        guard let data = UserDefaults.standard.data(forKey: kRatesKey) else { return nil }
        if let cached = try? JSONDecoder().decode(CachedRates.self, from: data) {
            return CachedRates(base: cached.base, rates: normalizedRates(cached.rates))
        }
        // 兼容旧版本缓存（仅存汇率字典）
        if let rates = try? JSONDecoder().decode([String: Double].self, from: data),
           let base = UserDefaults.standard.string(forKey: kBaseKey) {
            return CachedRates(base: base, rates: normalizedRates(rates))
        }
        return nil
    }

    // 统一大小写，避免汇率字典 key 大小写不一致导致换算失败
    private static func normalizedRates(_ rates: [String: Double]) -> [String: Double] {
        var normalized: [String: Double] = [:]
        normalized.reserveCapacity(rates.count * 2)
        for (code, value) in rates {
            let upper = code.uppercased()
            let lower = code.lowercased()
            normalized[upper] = value
            normalized[lower] = value
        }
        return normalized
    }
    
}
