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

/// 旧版（单槽）缓存的格式，只用于迁移
struct CachedRates: Codable {
    let base: String
    let rates: [String: Double]
}

/// 汇率服务。
///
/// 缓存**按 base 币种分槽**：首页用主币种、记账页用消费地币种、积分估值用积分币种、
/// 批量导入每张小票各自的币种 —— 之前只有一个槽，谁最后调用谁占着，其它页面每次切回来
/// 都要重新联网，记账页每敲一个数字就是一次请求；断网时 base 对不上就退回 `[base: 1.0]`，
/// 所有外币被当 1:1 加进总额。现在：同一天内每个 base 只请求一次，并发请求合并，
/// 失败先用过期缓存，最后才退回 1:1（且只含 base 自己，缺的币种由调用方按"没有汇率"处理）。
struct CurrencyService {

    struct CachedEntry: Codable {
        let fetchedAt: Date
        let rates: [String: Double]
    }

    /// 测试可以换成独立的 suite
    static var defaults: UserDefaults = .standard

    /// 进行中的请求：同一 base 的并发调用共用一次
    private static var inFlight: [String: Task<[String: Double], Never>] = [:]

    // --- 🚀 智能入口：获取汇率 ---
    // View 层只调用这个方法，不需要关心内部逻辑
    static func getRates(base: String = "CNY") async -> [String: Double] {
        let key = base.uppercased()

        if let entry = cachedEntry(for: key), isFresh(entry) {
            return entry.rates
        }
        if let running = inFlight[key] {
            return await running.value
        }

        let task = Task<[String: Double], Never> {
            print("🌍 正在联网更新汇率 (base: \(key))...")
            do {
                let rates = normalizedRates(try await fetchRemoteRates(base: key))
                guard !rates.isEmpty else {
                    throw NSError(domain: "CurrencyService", code: 204,
                                  userInfo: [NSLocalizedDescriptionKey: "汇率响应为空"])
                }
                store(rates, for: key)
                return rates
            } catch {
                print("❌ \(AppError.networkFailure(underlying: error).localizedDescription)")
                // 过期的缓存也比 1:1 强得多
                if let stale = cachedEntry(for: key) {
                    return stale.rates
                }
                return [key: 1.0, key.lowercased(): 1.0]
            }
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return await task.value
    }

    // MARK: - 缓存（按 base 分槽）

    static func isFresh(_ entry: CachedEntry, now: Date = Date()) -> Bool {
        Calendar.current.isDate(entry.fetchedAt, inSameDayAs: now)
    }

    static func cachedEntry(for base: String) -> CachedEntry? {
        loadAll()[base.uppercased()]
    }

    static func store(_ rates: [String: Double], for base: String, at date: Date = Date()) {
        var all = loadAll()
        all[base.uppercased()] = CachedEntry(fetchedAt: date, rates: normalizedRates(rates))
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: AppConfig.UserDefaultsKey.cachedExchangeRatesByBase)
        }
    }

    private static func loadAll() -> [String: CachedEntry] {
        if let data = defaults.data(forKey: AppConfig.UserDefaultsKey.cachedExchangeRatesByBase),
           let all = try? JSONDecoder().decode([String: CachedEntry].self, from: data) {
            return all
        }
        // 迁移旧版单槽缓存：当成一个 base 的条目
        if let legacy = loadLegacyRates() {
            let all = [legacy.base.uppercased(): legacy.entry]
            if let data = try? JSONEncoder().encode(all) {
                defaults.set(data, forKey: AppConfig.UserDefaultsKey.cachedExchangeRatesByBase)
            }
            return all
        }
        return [:]
    }

    private static func loadLegacyRates() -> (base: String, entry: CachedEntry)? {
        guard let data = defaults.data(forKey: AppConfig.UserDefaultsKey.cachedExchangeRates) else { return nil }
        let fetchedAt = defaults.object(forKey: AppConfig.UserDefaultsKey.lastFetchDate) as? Date ?? .distantPast
        if let cached = try? JSONDecoder().decode(CachedRates.self, from: data) {
            return (cached.base, CachedEntry(fetchedAt: fetchedAt, rates: normalizedRates(cached.rates)))
        }
        if let rates = try? JSONDecoder().decode([String: Double].self, from: data),
           let base = defaults.string(forKey: AppConfig.UserDefaultsKey.lastRatesBase) {
            return (base, CachedEntry(fetchedAt: fetchedAt, rates: normalizedRates(rates)))
        }
        return nil
    }

    // --- 内部方法：联网下载 (私有) ---
    private static func fetchRemoteRates(base: String) async throws -> [String: Double] {
        let urlString = "\(AppConfig.currencyAPIBaseURL)\(base.lowercased()).json"
        guard let url = URL(string: urlString) else { return [:] }

        // 用配置里的超时：URLSession.shared 默认 60 秒，弱网下首页会显示一分钟的 "..."
        let request = URLRequest(url: url, timeoutInterval: AppConfig.networkTimeout)
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(FrankfurterLatestResponse.self, from: data)
        return response.rates
    }

    // 统一大小写，避免汇率字典 key 大小写不一致导致换算失败
    static func normalizedRates(_ rates: [String: Double]) -> [String: Double] {
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
