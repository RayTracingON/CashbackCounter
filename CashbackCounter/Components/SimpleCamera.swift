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
    private var isConfigured = false
    
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
            
            // 1. 找摄像头
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
            let input = try AVCaptureDeviceInput(device: device)
            
            // 2. 连接输入输出
            if session.canAddInput(input) { session.addInput(input) }
            if session.canAddOutput(output) { session.addOutput(output) }
            
            session.commitConfiguration()
            isConfigured = true
            
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
