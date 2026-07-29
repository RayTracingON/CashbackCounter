//
//  PlaidAPIClient.swift
//  CashbackCounter
//
//  自建后端（plaid-backend）的网络层。所有和后端的往来都从这里过。
//

import Foundation

// MARK: - 错误

enum PlaidAPIError: LocalizedError {
    /// 本地根本没有会话 token —— 用户还没登录
    case notSignedIn
    /// 会话过期且自动续期也失败了，需要用户重新走一次登录
    case unauthorized
    /// Plaid 侧的问题。code 是 Plaid 的公开错误码，调用方靠它区分
    /// "再等等"（PRODUCT_NOT_READY）和"真的坏了"
    case plaid(code: String?, message: String?)
    /// 后端返回了非 2xx。message 是后端给的人话描述（可能为 nil）
    case server(status: Int, message: String?)
    case transport(Error)
    case decoding(Error)

    /// ⚠️ 这些是**会显示给用户**的文案，必须走 String(localized:) ——
    /// 它们不在 SwiftUI 的 Text 里，不会被自动提取和本地化。
    ///
    /// 注意 `.plaid` 和 `.server` 优先用后端给的 message：那是服务端按具体情况
    /// 生成的（"银行数据正在准备中"/"银行连接已失效"），比这里的兜底文案有用得多。
    /// 后端的多语言是另一个话题，目前只有中文。
    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return String(localized: "尚未登录，请先用 Apple ID 登录")
        case .unauthorized:
            return String(localized: "登录已过期，请重新登录")
        case .plaid(_, let message):
            return message ?? String(localized: "银行数据接口暂时不可用，请稍后重试")
        case .server(let status, let message):
            return message ?? String(localized: "服务器响应异常（状态码：\(status)）")
        case .transport(let error):
            return String(localized: "网络请求失败：\(error.localizedDescription)")
        case .decoding(let error):
            return String(localized: "数据解析失败：\(error.localizedDescription)")
        }
    }

    /// 刚绑定完 Plaid 还在向银行拉数据，通常 1–2 分钟内就绪。
    /// **这不是错误**，是需要等待的正常状态。
    var isProductNotReady: Bool {
        if case .plaid(let code, _) = self { return code == "PRODUCT_NOT_READY" }
        return false
    }

    /// 银行连接失效，必须让用户重新授权（Link update mode）。
    /// 光重试没有用。
    var needsReauthorization: Bool {
        if case .plaid(let code, _) = self { return code == "ITEM_LOGIN_REQUIRED" }
        return false
    }
}

// MARK: - 会话来源

/// 客户端不自己管理登录状态，只向 AuthService 要 token、以及在 401 时请它想办法。
/// 这样「怎么登录」和「怎么发请求」是两件互不知情的事，
/// 将来换认证方式（比如加上邮箱登录）不需要动这个文件。
@MainActor
protocol PlaidAPISessionDelegate: AnyObject {
    func currentSessionToken() -> String?
    /// 尝试静默恢复会话。返回 true 表示已拿到新 token，调用方可以重试。
    func recoverFromUnauthorized() async -> Bool
}

// MARK: - 客户端

final class PlaidAPIClient {

    static let shared = PlaidAPIClient()

    weak var sessionDelegate: PlaidAPISessionDelegate?

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    private init() {
        let config = URLSessionConfiguration.default
        // 后端跑在 Azure F1 上，冷启动要好几秒；5 秒（AppConfig.networkTimeout）
        // 对汇率接口够用，对这里会频繁误伤。
        config.timeoutIntervalForRequest = 30

        // waitsForConnectivity 让请求在「暂时没网」时排队等待而不是立刻失败，
        // 对移动端是对的。但它有个陷阱：等待期**不受 timeoutIntervalForRequest 约束**，
        // 受 timeoutIntervalForResource 约束，而后者默认是 7 天。
        // 不设它的话，一个连不上的地址（比如 Debug 构建指着一个没在跑的本地后端）
        // 不会报错，只会让 UI 无限转圈 —— 症状和"服务器很慢"完全一样，极难判断。
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 60

        self.session = URLSession(configuration: config)

        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    // MARK: - 对外入口

    func get<Response: Decodable>(_ path: String,
                                 query: [URLQueryItem] = [],
                                 as type: Response.Type = Response.self) async throws -> Response {
        try await send(method: "GET", path: path, query: query, body: Optional<Never>.none).value
    }

    /// 同上，但把响应头也带回来。
    ///
    /// 交易查询需要读 `X-Max-Transactions` 判断结果有没有被截断 ——
    /// 截断了却当成"这段时间就这么多"，就会**静默丢掉**一部分历史交易，
    /// 而且用户永远不会发现。
    func getWithHeaders<Response: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        as type: Response.Type = Response.self
    ) async throws -> (value: Response, headers: [AnyHashable: Any]) {
        let result: (value: Response, headers: [AnyHashable: Any]) =
            try await send(method: "GET", path: path, query: query, body: Optional<Never>.none)
        return result
    }

    func post<Response: Decodable>(_ path: String,
                                  query: [URLQueryItem] = [],
                                  as type: Response.Type = Response.self) async throws -> Response {
        try await send(method: "POST", path: path, query: query, body: Optional<Never>.none).value
    }

    func post<Body: Encodable, Response: Decodable>(_ path: String,
                                                   body: Body,
                                                   query: [URLQueryItem] = [],
                                                   as type: Response.Type = Response.self) async throws -> Response {
        try await send(method: "POST", path: path, query: query, body: body).value
    }

    func delete<Response: Decodable>(_ path: String,
                                    query: [URLQueryItem] = [],
                                    as type: Response.Type = Response.self) async throws -> Response {
        try await send(method: "DELETE", path: path, query: query, body: Optional<Never>.none).value
    }

    /// 免认证端点专用（目前只有 POST /api/auth/apple）。
    /// 单独开一个入口而不是给 send 加参数，是为了让「哪些请求不带凭据」
    /// 在调用处一眼可见，不会被默认值悄悄改变。
    func postUnauthenticated<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let request = try makeRequest(method: "POST", path: path, query: [], body: body, token: nil)
        let (data, response) = try await perform(request)
        return try handle(data: data, response: response)
    }

    // MARK: - 内部

    /// 带认证的请求。遇到 401 时请 AuthService 续期，成功则**只重试一次**。
    ///
    /// 只重试一次是刻意的：如果续期后仍然 401，那就不是「过期」而是别的问题
    /// （token 被吊销、后端换了签名密钥、Bundle ID 配错），
    /// 无限重试只会变成一个打自己后端的死循环。
    private func send<Body: Encodable, Response: Decodable>(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: Body?
    ) async throws -> (value: Response, headers: [AnyHashable: Any]) {

        guard let token = await sessionDelegate?.currentSessionToken() else {
            throw PlaidAPIError.notSignedIn
        }

        let request = try makeRequest(method: method, path: path, query: query, body: body, token: token)
        let (data, response) = try await perform(request)

        if (response as? HTTPURLResponse)?.statusCode == 401 {
            guard let delegate = sessionDelegate,
                  await delegate.recoverFromUnauthorized(),
                  let refreshed = await delegate.currentSessionToken() else {
                throw PlaidAPIError.unauthorized
            }

            let retry = try makeRequest(method: method, path: path, query: query, body: body, token: refreshed)
            let (retryData, retryResponse) = try await perform(retry)
            return (try handle(data: retryData, response: retryResponse),
                    (retryResponse as? HTTPURLResponse)?.allHeaderFields ?? [:])
        }

        return (try handle(data: data, response: response),
                (response as? HTTPURLResponse)?.allHeaderFields ?? [:])
    }

    private func makeRequest<Body: Encodable>(method: String,
                                             path: String,
                                             query: [URLQueryItem],
                                             body: Body?,
                                             token: String?) throws -> URLRequest {

        var components = URLComponents(
            url: AppConfig.Backend.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
        }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }

        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        #if DEBUG
        // 只在 Debug 里打，且只打方法和 URL —— 绝不打请求体或 Authorization 头，
        // 那里面是 identityToken 和会话 token。
        let started = Date()
        print("🌐 \(request.httpMethod ?? "?") \(request.url?.absoluteString ?? "?")")
        #endif

        do {
            let result = try await session.data(for: request)
            #if DEBUG
            let status = (result.1 as? HTTPURLResponse)?.statusCode ?? -1
            print("🌐 ← \(status)  \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            #endif
            return result
        } catch {
            #if DEBUG
            print("🌐 ✕ \(error.localizedDescription)  \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            #endif
            throw PlaidAPIError.transport(error)
        }
    }

    private func handle<Response: Decodable>(data: Data, response: URLResponse) throws -> Response {
        guard let http = response as? HTTPURLResponse else {
            throw PlaidAPIError.server(status: -1, message: nil)
        }

        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw PlaidAPIError.unauthorized
            }

            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if (json?["error"] as? String) == "plaid_error" {
                throw PlaidAPIError.plaid(
                    code: json?["plaidErrorCode"] as? String,
                    message: json?["message"] as? String)
            }

            throw PlaidAPIError.server(status: http.statusCode, message: Self.extractMessage(from: data))
        }

        // 有些端点（将来的 204）没有响应体，而调用方声明的是 EmptyResponse
        if Response.self == EmptyResponse.self {
            return EmptyResponse() as! Response
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw PlaidAPIError.decoding(error)
        }
    }

    /// 后端的错误体形如 {"error":"...","message":"人话描述"}；
    /// Spring 默认的错误体只有 "error"。两种都尽量取出点有用的东西。
    private static func extractMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let message = json["message"] as? String, !message.isEmpty {
            return message
        }
        return json["error"] as? String
    }
}

/// 给「只关心成功与否、不关心响应体」的调用点用
struct EmptyResponse: Decodable {}
