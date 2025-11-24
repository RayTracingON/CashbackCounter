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
    
    // 检查权限并启动
    func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { status in
                if status { self.setup() }
            }
        case .authorized:
            setup()
        default:
            return
        }
    }
    
    // 配置相机输入输出
    func setup() {
        do {
            session.beginConfiguration()
            
            // 1. 找摄像头
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
            let input = try AVCaptureDeviceInput(device: device)
            
            // 2. 连接输入输出
            if session.canAddInput(input) { session.addInput(input) }
            if session.canAddOutput(output) { session.addOutput(output) }
            
            session.commitConfiguration()
            
            // 3. 开始流动画面 (必须在后台线程)
            DispatchQueue.global(qos: .background).async {
                self.session.startRunning()
            }
        } catch {
            print(error.localizedDescription)
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
        self.recentImage = UIImage(data: data)
    }
}

// 2. 也是一个 UIViewRepresentable，把相机画面转成 View
struct CameraPreview: UIViewRepresentable {
    @ObservedObject var cameraService: CameraService
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: UIScreen.main.bounds)
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: cameraService.session)
        previewLayer.frame = view.frame
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
}
