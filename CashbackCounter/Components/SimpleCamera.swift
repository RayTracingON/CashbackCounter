//
//  SimpleCamera.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/24/25.
//

import SwiftUI
import AVFoundation
import Combine



// 1. 相机逻辑控制器
class CameraService: NSObject, ObservableObject {
    @Published var session = AVCaptureSession()
    @Published var output = AVCapturePhotoOutput()
    @Published var recentImage: UIImage? // 存刚才拍的照片
    @Published var permissionDenied = false // Bug 3: 权限被拒绝时通知 UI
    /// iPad 分屏 / 台前调度时系统收走了相机（机型不支持多任务下用相机），取景框会黑掉
    @Published var isUnavailableInMultitasking = false
    private var isConfigured = false

    // MARK: 画面方向
    // 取景层和拍出来的照片默认都按竖屏方向出图：iPad 横放、iPhone Duo 展开转个方向，
    // 画面就是歪的。RotationCoordinator 按设备姿态和取景层所在界面的方向给出该转的角度。
    private var videoDevice: AVCaptureDevice?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    /// 只在 setup（主线程）里写一次、deinit 里读来注销，不会并发访问
    private nonisolated(unsafe) var interruptionObservers: [NSObjectProtocol] = []

    deinit {
        // 切 App 语言时整棵视图树按 id 重建，旧的 CameraService 会被释放，通知中心里的观察者要跟着注销
        interruptionObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// 取景层建好后交过来（CameraPreview.makeUIView）。和 setup 谁先谁后都行，两边都齐了才建 RotationCoordinator
    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        guard layer !== previewLayer else { return }
        previewLayer = layer
        configureRotationIfReady()
    }

    private func configureRotationIfReady() {
        guard let videoDevice, let previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: videoDevice, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        previewLayer.connection?.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: .new) { [weak previewLayer] coordinator, _ in
            previewLayer?.connection?.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
        }
    }

    /// 分屏时相机被系统收走 / 还回来：只关心「多个 App 同时在前台」这一种原因，来电之类的打断照旧黑一下就好
    private func observeInterruptions() {
        let center = NotificationCenter.default
        interruptionObservers = [
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] note in
                let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int)
                    .flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
                guard reason == .videoDeviceNotAvailableWithMultipleForegroundApps else { return }
                MainActor.assumeIsolated { self?.isUnavailableInMultitasking = true }
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isUnavailableInMultitasking = false }
            },
        ]
    }
    
    // 检查权限并启动
    func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { status in
                DispatchQueue.main.async {
                    if status {
                        self.setup()
                    } else {
                        self.permissionDenied = true
                    }
                }
            }
        case .authorized:
            setup()
        case .denied, .restricted:
            DispatchQueue.main.async {
                self.permissionDenied = true
            }
        @unknown default:
            return
        }
    }
    
    // 配置相机输入输出
    func setup() {
        // 避免重复配置，如果已经配置过只需确保会话正在运行
        if isConfigured {
            startSessionIfNeeded()
            return
        }
        
        do {
            session.beginConfiguration()
            
            // 1. 找摄像头。没有后置摄像头（模拟器 / 个别设备）时也走"不可用"分支，
            // 否则快门按钮照常可点，capturePhoto 会因为 output 没接入 session 直接崩
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                session.commitConfiguration()
                permissionDenied = true
                return
            }
            let input = try AVCaptureDeviceInput(device: device)
            
            // 2. 连接输入输出
            if session.canAddInput(input) { session.addInput(input) }
            if session.canAddOutput(output) { session.addOutput(output) }
            
            // iPad 分屏 / 台前调度时默认会把相机收走（取景框直接黑掉）；机型支持的话申请继续用
            if session.isMultitaskingCameraAccessSupported {
                session.isMultitaskingCameraAccessEnabled = true
            }

            session.commitConfiguration()
            isConfigured = true
            videoDevice = device
            configureRotationIfReady()
            observeInterruptions()
            
            // 3. 开始流动画面 (必须在后台线程)
            startSessionIfNeeded()
        } catch {
            print(error.localizedDescription)
        }
    }
    
    private func startSessionIfNeeded() {
        guard !session.isRunning else { return }
        DispatchQueue.global(qos: .background).async {
            self.session.startRunning()
        }
    }
    
    func stopSession() {
        guard session.isRunning else { return }
        DispatchQueue.global(qos: .background).async {
            self.session.stopRunning()
        }
    }
    
    // 拍照动作
    func takePhoto() {
        // 权限被拒 / 没有摄像头时 output 根本没挂到 session 上，这时 capturePhoto 会抛
        // NSInvalidArgumentException（"No active and enabled video connection"）直接崩。
        // 会话还没启动完成时同样忽略这一下
        guard isConfigured,
              session.isRunning,
              let connection = output.connection(with: .video),
              connection.isEnabled, connection.isActive else {
            print("⚠️ 相机未就绪，忽略本次拍照")
            return
        }
        // 照片按拍的那一刻设备怎么拿着来摆正，不然横着拍的小票存下来是躺着的
        if let rotationCoordinator {
            let angle = rotationCoordinator.videoRotationAngleForHorizonLevelCapture
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
        let settings = AVCapturePhotoSettings()
        output.capturePhoto(with: settings, delegate: self)
    }
}

// 接收拍照结果
extension CameraService: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation() else { return }
        // Bug 2 修复：回调在后台线程，必须切主线程更新 @Published 属性
        DispatchQueue.main.async {
            self.recentImage = UIImage(data: data)
        }
    }
}

// 2. 也是一个 UIViewRepresentable，把相机画面转成 View
final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    
    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            fatalError("Layer is not AVCaptureVideoPreviewLayer.")
        }
        return layer
    }
}

struct CameraPreview: UIViewRepresentable {
    @ObservedObject var cameraService: CameraService
    typealias UIViewType = CameraPreviewView
    
    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView(frame: .zero)
        view.previewLayer.session = cameraService.session
        view.previewLayer.videoGravity = .resizeAspectFill
        cameraService.attachPreviewLayer(view.previewLayer)
        return view
    }
    
    func updateUIView(_ uiView: CameraPreviewView, context: Context) {}
}

// MARK: - Previews

#if DEBUG
#Preview("相机预览层") {
    // 画布和模拟器都没有摄像头，这里只验证 AVCaptureVideoPreviewLayer 能装起来不崩，
    // 真实画面必须真机看。
    CameraPreview(cameraService: CameraService())
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            Text("画布无摄像头，画面为空属正常")
                .font(.footnote)
                .padding(8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 40)
        }
}
#endif
