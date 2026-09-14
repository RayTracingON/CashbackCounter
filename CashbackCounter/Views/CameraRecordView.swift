//
//  CameraRecordView.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/23/25.
//

import SwiftUI

struct CameraRecordView: View {
    // 1. 引入刚才写的相机引擎
    @StateObject var cameraService = CameraService()
    
    // 2. 控制跳转
    @State private var showAddSheet = false      // 跳转去记账页
    @State private var showPhotoLibrary = false  // 打开相册
    
    // 3. 选中的图片 (无论是拍的还是相册选的)
    @State private var selectedImage: UIImage?
    @State private var isTargeted = false
    
    var body: some View {
        ZStack {
            // --- 层级 1: 相机画面 (铺满全屏) ---
            CameraPreview(cameraService: cameraService)
                .ignoresSafeArea()
            // --- 层级 2: 拖拽提示层 (当用户拖着文件悬停时显示) ---
            if isTargeted {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
                    .overlay(
                        VStack(spacing: 20) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: DesignConstants.Size.dropIndicatorIcon))
                                .foregroundColor(.white)
                            Text("松手导入图片")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                        }
                    )
            }
            // --- 层级 2.5: 相机权限被拒绝提示 ---
            if cameraService.permissionDenied {
                Color.black.opacity(0.85)
                    .ignoresSafeArea()
                    .overlay(
                        VStack(spacing: 16) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 48))
                                .foregroundColor(.white.opacity(0.6))
                            Text("无法访问相机")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                            Text("请在系统设置中开启相机权限")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.7))
                            Button(action: {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }) {
                                Text("前往设置")
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 10)
                                    .background(Color.white)
                                    .foregroundColor(.black)
                                    .clipShape(Capsule())
                            }
                            .padding(.top, 8)
                        }
                    )
            }
            // --- 层级 3: 操作按钮 ---
            VStack {
                Spacer() // 把按钮推到底部
                
                HStack {
                    // 左下角：相册按钮
                    Button(action: {
                        showPhotoLibrary = true
                    }) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.largeTitle)
                            .foregroundColor(.white)
                            .frame(width: DesignConstants.Size.cameraSideButton, height: DesignConstants.Size.cameraSideButton)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    
                    Spacer()
                    
                    // 中间：拍照大按钮
                    Button(action: {
                        cameraService.takePhoto()
                    }) {
                        ZStack {
                            Circle()
                                .stroke(Color.white, lineWidth: 4)
                                .frame(width: DesignConstants.Size.cameraButtonOuter, height: DesignConstants.Size.cameraButtonOuter)
                            Circle()
                                .fill(Color.white)
                                .frame(width: DesignConstants.Size.cameraButtonInner, height: DesignConstants.Size.cameraButtonInner)
                        }
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        // 核心逻辑：
                        // 1. 确保图片为空 (表示纯文本记账)
                        selectedImage = nil
                        // 2. 打开记账页面
                        showAddSheet = true
                        }) {
                            Image(systemName: "square.and.pencil") // ✏️ 记账图标
                                .font(.largeTitle)
                                .foregroundColor(.white)
                                .frame(width: DesignConstants.Size.cameraSideButton, height: DesignConstants.Size.cameraSideButton) // 保持和左边一样大，对称美
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                    
                }
                .padding(.horizontal, DesignConstants.Spacing.bottomHorizontalPadding)
                .padding(.bottom, DesignConstants.Spacing.bottomPadding)
            }
        }
        // 👇👇👇 核心修改：添加拖拽目标 👇👇👇
        .dropDestination(for: Data.self) { items, location in
            // items 是一个 [Data] 数组
            guard let item = items.first, let image = UIImage(data: item) else {
                return false // 如果不是图片数据，拒绝
            }
            
            // 赋值图片，会自动触发 onChange 跳转
            self.selectedImage = image
            return true
        } isTargeted: { targeted in
            // 监听：用户是否拖着文件悬停在上方
            withAnimation {
                self.isTargeted = targeted
            }
        }
        .onAppear {
            cameraService.checkPermissions() // 页面出现时，启动相机
        }
        .onDisappear {
            cameraService.stopSession() // 页面消失时，关闭相机
        }
        // 监听：如果相机拍到了照片，赋值给 selectedImage（统一由下面的 onChange 处理跳转）
        .onChange(of: cameraService.recentImage) { oldValue, newImage in
            if let img = newImage {
                self.selectedImage = img
            }
        }
        // 弹窗 1：相册
        .sheet(isPresented: $showPhotoLibrary) {
            ImagePicker(selectedImage: $selectedImage, sourceType: .photoLibrary)
        }
        // 监听：统一跳转入口（无论拍照/相册/拖拽，都经这里）
        .onChange(of: selectedImage) { oldValue, newImage in
            if newImage != nil && !showAddSheet {
                showAddSheet = true
            }
        }
        // 弹窗 2：去记账页面 (带上图片！)
        .sheet(isPresented: $showAddSheet) {
            // 👇 记得这里要清空 selectedImage，防止下次回来还有值
            AddTransactionView(image: selectedImage, onSaved: {
                 // 保存成功后的回调
            })
            .onDisappear {
                selectedImage = nil
                cameraService.recentImage = nil
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("拍一笔") {
    // 画布/模拟器都没有摄像头，取景框是黑的；快门、相册入口、拖拽提示层照样能点。
    CameraRecordView()
        .previewEnvironment()
}
#endif
