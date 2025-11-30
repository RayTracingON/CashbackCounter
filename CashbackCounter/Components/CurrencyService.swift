import Foundation

// 1. 定义 API 响应结构 (保持不变)
struct FrankfurterLatestResponse: Codable {
    let amount: Double
    let base: String
    let date: String
    let rates: [String: Double]
}

struct CurrencyService {

    // --- 缓存配置 ---
    private static let kRatesKey = "cached_exchange_rates" // 存汇率数据的 Key
    private static let cacheValidity: TimeInterval = 12 * 60 * 60 // 12h

    private struct CachedRates: Codable {
        let base: String
        let fetchedAt: Date
        let rates: [String: Double]
    }

    // --- 🚀 智能入口：获取汇率 ---
    // View 层只调用这个方法，不需要关心内部逻辑
    static func getRates(base: String = "CNY") async -> [String: Double] {

        if let cached = loadLocalRates(),
           cached.base.caseInsensitiveCompare(base) == .orderedSame,
           abs(cached.fetchedAt.timeIntervalSinceNow) < cacheValidity {
            print("✅ 汇率使用缓存（基准：\(cached.base)）")
            return cached.rates
        }

        print("🌍 正在联网更新汇率 (base: \(base))...")
        do {
            let rates = try await fetchRemoteRates(base: base)
            saveRatesLocally(rates: rates, base: base)
            return rates
        } catch {
            print("❌ 网络请求失败: \(error)")
            if let cached = loadLocalRates(), cached.base.caseInsensitiveCompare(base) == .orderedSame {
                return cached.rates
            }
            return [base: 1.0]
        }
    }

    // --- 内部方法：联网下载 (私有) ---
    private static func fetchRemoteRates(base: String) async throws -> [String: Double] {
        let urlString = "https://api.frankfurter.app/latest?from=\(base)"
        guard let url = URL(string: urlString) else { return [:] }

        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(FrankfurterLatestResponse.self, from: data)
        return response.rates
    }

    // --- 内部方法：存入 UserDefaults ---
    private static func saveRatesLocally(rates: [String: Double], base: String) {
        let cache = CachedRates(base: base, fetchedAt: Date(), rates: rates)
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: kRatesKey)
        }
    }

    // --- 内部方法：读取 UserDefaults ---
    private static func loadLocalRates() -> CachedRates? {
        guard let data = UserDefaults.standard.data(forKey: kRatesKey) else { return nil }
        return try? JSONDecoder().decode(CachedRates.self, from: data)
    }
    
    static func fetchRate(from source: String, to target: String) async throws -> Double {

        if source == target { return 1.0 }

        let cachedRates = await getRates(base: source)
        if let rate = cachedRates[target] {
            return rate
        }

        // 兜底：直接请求单个币种，避免接口没有覆盖
        let urlString = "https://api.frankfurter.app/latest?from=\(source)&to=\(target)"
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(FrankfurterLatestResponse.self, from: data)

        if let rate = response.rates[target] {
            return rate
        } else {
            throw URLError(.cannotParseResponse)
        }
    }
}
