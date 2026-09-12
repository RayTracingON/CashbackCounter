//
//  AppError.swift
//  CashbackCounter
//
//  统一错误类型 — 替代各组件中不一致的 print("❌") / try? / 静默失败模式。
//  ViewModel 层可以根据 AppError 类型决定是否向用户展示错误提示。
//

import Foundation

enum AppError: LocalizedError {

    // MARK: - 网络错误
    /// 网络请求失败
    case networkFailure(underlying: Error)
    /// 服务器返回非 200 状态码
    case invalidResponse(statusCode: Int)

    // MARK: - 数据导入/导出错误
    /// 导入失败
    case importFailed(reason: String)
    /// 导出失败
    case exportFailed(reason: String)

    // MARK: - 数据解析错误
    /// 数据格式损坏或无法解析
    case dataCorrupted(detail: String)
    /// JSON/CSV 解码失败
    case decodingFailed(detail: String)

    // MARK: - 用户操作错误
    /// 缺少必填字段
    case missingRequiredField(field: String)
    /// 文件访问被拒绝
    case fileAccessDenied(path: String)

    // MARK: - 数据库操作错误
    /// SwiftData 保存失败
    case saveFailed(underlying: Error)
    /// SwiftData 查询失败
    case fetchFailed(underlying: Error)
    /// 数据删除失败
    case deleteFailed(underlying: Error)

    // MARK: - LocalizedError

    var errorDescription: String? {
        switch self {
        case .networkFailure(let error):
            return String.loc("网络请求失败：\(error.localizedDescription)")
        case .invalidResponse(let code):
            return String.loc("服务器响应异常（状态码：\(code)）")
        case .importFailed(let reason):
            return String.loc("导入失败：\(reason)")
        case .exportFailed(let reason):
            return String.loc("导出失败：\(reason)")
        case .dataCorrupted(let detail):
            return String.loc("数据格式异常：\(detail)")
        case .decodingFailed(let detail):
            return String.loc("数据解析失败：\(detail)")
        case .missingRequiredField(let field):
            return String.loc("缺少必填信息：\(field)")
        case .fileAccessDenied(let path):
            return String.loc("无法访问文件：\(path)")
        case .saveFailed(let error):
            return String.loc("保存失败：\(error.localizedDescription)")
        case .fetchFailed(let error):
            return String.loc("查询失败：\(error.localizedDescription)")
        case .deleteFailed(let error):
            return String.loc("删除失败：\(error.localizedDescription)")
        }
    }
}
