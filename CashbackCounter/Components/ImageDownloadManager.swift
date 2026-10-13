//
//  ImageDownloadManager.swift
//  CashbackCounter
//
//  Created by AI Assistant on 12/17/25.
//

import SwiftUI
import UIKit
import Combine

// MARK: - 1. 内置常量定义
struct AppConstants {
    struct ErrorMessages {
        static let invalidURL = "无效的 URL"
        static let downloadCancelled = "下载已取消"
        static let parseError = "图片解析失败"
        static let fileReadErrorPrefix = "文件读取错误: "
        static let downloadErrorPrefix = "下载错误: "
        static let serverErrorPrefix = "服务器错误"
    }
}

// MARK: - 2. 内置图片缓存 (Actor)
actor ImageCache {
    static let shared = ImageCache()

    /// 缓存条目同时带原始字节：命中时直接返回原数据，不再 `pngData()` 重编码 ——
    /// 把一张压缩过的 JPEG 卡面转成 PNG 存进 `cardImageData` 会把外置存储撑大数倍。
    private final class Entry {
        let image: UIImage
        let data: Data
        init(image: UIImage, data: Data) {
            self.image = image
            self.data = data
        }
    }

    /// NSCache 有上限且会在内存警告时自动清理；之前是无上限的字典
    private let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 200
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    func load(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)?.image
    }

    func loadData(forKey key: String) -> Data? {
        cache.object(forKey: key as NSString)?.data
    }

    func save(_ image: UIImage, data: Data, forKey key: String) {
        cache.setObject(Entry(image: image, data: data), forKey: key as NSString, cost: data.count)
    }
}

// MARK: - 3. 图片下载管理器
/// 图片下载管理器，支持进度追踪和临时存储
@MainActor
class ImageDownloadManager: NSObject, ObservableObject {
    @Published var downloadProgress: Double = 0.0
    @Published var isDownloading: Bool = false
    @Published var downloadedImage: UIImage?
    @Published var errorMessage: String?
    static let shared = ImageDownloadManager()
    
    private var downloadTask: URLSessionDownloadTask?
    private lazy var urlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        let delegate = SessionDelegate(parent: self)
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: .main)
    }()
    
    // 移除 Logger，改为 print
    // private let logger = Logger(...)
    
    // MARK: - Session Delegate Wrapper
    
    private class SessionDelegate: NSObject, URLSessionDownloadDelegate {
        weak var parent: ImageDownloadManager?
        
        init(parent: ImageDownloadManager) {
            self.parent = parent
        }
        
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            parent?.handleProgress(totalBytesWritten: totalBytesWritten, totalBytesExpectedToWrite: totalBytesExpectedToWrite)
        }
        
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            parent?.handleFinishDownloading(task: downloadTask, location: location)
        }
        
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            parent?.handleCompletion(task: task, error: error)
        }
    }
    
    // MARK: - Public Methods
    

    /// 下载图片（带进度），支持网络 URL 和本地 Assets
        /// - Parameter urlString: 图片的 URL 字符串 或 本地 Assets 名称
        func downloadImage(from urlString: String) async {
            print("🚀 [ImageDownloadManager] 开始获取图片: \(urlString)")
            
            // 1. Check Cache
            if let cachedImage = await ImageCache.shared.load(forKey: urlString) {
                print("✅ [ImageDownloadManager] 命中缓存，跳过下载")
                handleSuccess(image: cachedImage)
                return
            }
            
            // 2. 判断来源：网络 URL 还是本地 Assets
            if urlString.lowercased().hasPrefix("http") {
                
                // --- A. 网络下载 (原有逻辑) ---
                guard let url = URL(string: urlString) else {
                    handleError(AppConstants.ErrorMessages.invalidURL)
                    return
                }
                
                resetState()
                isDownloading = true
                
                // Create task
                downloadTask = urlSession.downloadTask(with: url)
                downloadTask?.resume()
                
            } else {
                
                // --- B. 本地 Assets 读取 (新增逻辑) ---
                print("📂 [ImageDownloadManager] 尝试从 Assets 加载: \(urlString)")
                
                resetState()
                isDownloading = true // 标记开始，虽然很快
                
                // 尝试加载
                if let image = UIImage(named: urlString) {
                    // 为了统一行为，也存入缓存
                    if let data = image.pngData() {
                        await ImageCache.shared.save(image, data: data, forKey: urlString)
                    }
                    
                    print("✅ [ImageDownloadManager] Assets 加载成功")
                    // 直接调用成功处理，它会设置 progress = 1.0, isDownloading = false
                    handleSuccess(image: image)
                    
                } else {
                    print("⚠️ [ImageDownloadManager] Assets 未找到图片: \(urlString)")
                    handleError("未在本地 Assets 找到图片: \(urlString)")
                }
            }
        }
    
    /// 取消下载
    func cancelDownload() {
        print("🛑 [ImageDownloadManager] 取消下载")
        downloadTask?.cancel()
        isDownloading = false
        downloadProgress = 0.0
        errorMessage = AppConstants.ErrorMessages.downloadCancelled
    }
    
    /// 清理下载的图片（当用户取消保存时调用）
    func cleanup() {
        print("🧹 [ImageDownloadManager] 清理资源")
        downloadedImage = nil
        downloadProgress = 0.0
        errorMessage = nil
        downloadTask = nil
    }
    /// 专门用于获取图片 Data (支持缓存 + 本地 Assets)，适合用于数据库存储
        func downloadImageData(from urlString: String) async -> Data? {
            // 1. 检查缓存：直接返回当初存进去的原始字节
            if let cachedData = await ImageCache.shared.loadData(forKey: urlString) {
                print("✅ [ImageDownloadManager] 命中缓存，直接返回数据")
                return cachedData
            }
            
            // 2. 判断来源：网络 URL 还是本地 Assets
            // 使用 simple check：如果包含 http/https 则视为网络图片
            if urlString.lowercased().hasPrefix("http") {
                
                // --- A. 网络下载逻辑 ---
                guard let url = URL(string: urlString) else { return nil }
                
                do {
                    print("🚀 [ImageDownloadManager] 开始下载数据: \(urlString)")
                    // 使用简单的 data(from:) API
                    let (data, _) = try await URLSession.shared.data(from: url)
                    
                    // 3. 下载成功后，存入缓存
                    if let image = UIImage(data: data) {
                        await ImageCache.shared.save(image, data: data, forKey: urlString)
                    }
                    
                    return data
                } catch {
                    print("❌ [ImageDownloadManager] \(AppError.networkFailure(underlying: error).localizedDescription)")
                    return nil
                }
                
            } else {
                
                // --- B. 本地 Assets 读取逻辑 ---
                print("📂 [ImageDownloadManager] 尝试从 Assets 加载: \(urlString)")
                
                // 因为 ImageDownloadManager 是 @MainActor，这里可以直接调用 UIImage(named:)
                // 注意：UIImage(named:) 必须在主线程调用才安全
                if let image = UIImage(named: urlString) {
                    // 转为 Data (推荐用 pngData 以保留透明度，或者 jpegData)
                    if let data = image.pngData() {
                        print("✅ [ImageDownloadManager] Assets 加载成功")
                        
                        // 同样存入缓存，统一管理，下次读取更快
                        await ImageCache.shared.save(image, data: data, forKey: urlString)
                        return data
                    }
                }
                
                print("⚠️ [ImageDownloadManager] Assets 未找到图片: \(urlString)")
                return nil
            }
        }
    
    // MARK: - Private Helpers
    
    private func resetState() {
        isDownloading = false
        downloadProgress = 0.0
        errorMessage = nil
        downloadedImage = nil
    }
    
    private func handleSuccess(image: UIImage) {
        self.isDownloading = false
        self.downloadProgress = 1.0
        self.errorMessage = nil
        self.downloadedImage = image
    }
    
    private func handleError(_ message: String) {
        print("❌ [ImageDownloadManager] 错误: \(message)")
        self.isDownloading = false
        self.errorMessage = message
    }
    
    // MARK: - Delegate Handlers
    
    nonisolated fileprivate func handleProgress(totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        
        Task { @MainActor in
            self.downloadProgress = progress
        }
    }
    
    nonisolated fileprivate func handleFinishDownloading(task: URLSessionDownloadTask, location: URL) {
        guard let originalURL = task.originalRequest?.url?.absoluteString else { return }
        
        // Move file to a safe place or read data immediately
        do {
            let data = try Data(contentsOf: location)
            
            Task { @MainActor in
                guard let image = UIImage(data: data) else {
                    self.handleError(AppConstants.ErrorMessages.parseError)
                    return
                }
                
                // Cache logic
                await ImageCache.shared.save(image, data: data, forKey: originalURL)
                
                self.handleSuccess(image: image)
                print("✅ [ImageDownloadManager] 下载完成并已缓存")
            }
        } catch {
            Task { @MainActor in
                self.handleError("\(AppConstants.ErrorMessages.fileReadErrorPrefix)\(error.localizedDescription)")
            }
        }
    }
    
    nonisolated fileprivate func handleCompletion(task: URLSessionTask, error: Error?) {
        if let error = error {
            // Ignore cancellation error
            if (error as NSError).code == NSURLErrorCancelled {
                return
            }
            
            Task { @MainActor in
                self.handleError("\(AppConstants.ErrorMessages.downloadErrorPrefix)\(error.localizedDescription)")
            }
        } else {
             // Success is handled in didFinishDownloadingTo
             // But we need to check HTTP status codes if needed.
             if let httpResponse = task.response as? HTTPURLResponse,
                !(200...299).contains(httpResponse.statusCode) {
                 Task { @MainActor in
                     self.handleError("\(AppConstants.ErrorMessages.serverErrorPrefix) (状态码: \(httpResponse.statusCode))")
                 }
             }
        }
    }
}
