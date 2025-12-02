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
    private static let kDateKey = "last_fetch_date"        // 存上次更新时间的 Key
    private static let kBaseKey = "last_rates_base"        // 存上次汇率基准币种
    
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
                return cachedRates
            }
        }
        
        // 2. 如果没缓存，或者数据过期了 -> 联网下载
        print("🌍 正在联网更新汇率...")
        do {
            let rates = try await fetchRemoteRates(base: base)
            // 下载成功后，立刻存入本地
            saveRatesLocally(rates, base: base)
            return rates
        } catch {
            print("❌ 网络请求失败: \(error)")
            // 3. 兜底：万一断网了，尝试读取旧的缓存（哪怕过期了也比没有强）
            return loadLocalRates() ?? [:]
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
    private static func saveRatesLocally(_ rates: [String: Double], base: String) {
        // 1. 存汇率 (字典自动转 Data)
        if let data = try? JSONEncoder().encode(rates) {
            UserDefaults.standard.set(data, forKey: kRatesKey)
        }
        // 2. 存时间 (存当前时间)
        UserDefaults.standard.set(Date(), forKey: kDateKey)
        // 3. 存当前基准币种
        UserDefaults.standard.set(base, forKey: kBaseKey)
    }
    
    // --- 内部方法：读取 UserDefaults ---
    private static func loadLocalRates() -> [String: Double]? {
        guard let data = UserDefaults.standard.data(forKey: kRatesKey) else { return nil }
        return try? JSONDecoder().decode([String: Double].self, from: data)
    }
    
    static func fetchRate(from source: String, to target: String) async throws -> Double {
            
            // 如果币种相同，直接返回 1.0
            if source == target { return 1.0 }
            
            // 构造 URL
            // Frankfurter API: https://api.frankfurter.app/latest?from=USD&to=CNY
            let urlString = "https://api.frankfurter.app/latest?from=\(source)&to=\(target)"
            
            guard let url = URL(string: urlString) else {
                throw URLError(.badURL)
            }
            
            // 发起网络请求
            let (data, _) = try await URLSession.shared.data(from: url)
            
            // 解析 JSON
            let response = try JSONDecoder().decode(FrankfurterLatestResponse.self, from: data)
            
            // 获取目标汇率
            if let rate = response.rates[target] {
                return rate
            } else {
                throw URLError(.cannotParseResponse)
            }
        }
}
