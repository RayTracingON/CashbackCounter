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
    
    var body: some View {
        ZStack {
            // --- 层级 1: 相机画面 (铺满全屏) ---
            CameraPreview(cameraService: cameraService)
                .ignoresSafeArea()
            
            // --- 层级 2: 操作按钮 ---
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
                            .frame(width: 60, height: 60)
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
                                .frame(width: 70, height: 70)
                            Circle()
                                .fill(Color.white)
                                .frame(width: 60, height: 60)
                        }
                    }
                    
                    Spacer()
                    
                    // 右下角：占位符 (为了布局平衡)
                    Color.clear.frame(width: 60, height: 60)
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 50)
            }
        }
        .onAppear {
            cameraService.checkPermissions() // 页面出现时，启动相机
        }
        // 监听：如果相机拍到了照片，就跳转
        .onChange(of: cameraService.recentImage) { oldValue, newImage in
            if let img = newImage {
                self.selectedImage = img
                self.showAddSheet = true
            }
        }
        // 弹窗 1：相册
        .sheet(isPresented: $showPhotoLibrary) {
            ImagePicker(selectedImage: $selectedImage, sourceType: .photoLibrary)
        }
        // 监听：如果从相册选了图，也跳转
        .onChange(of: selectedImage) { oldValue, newImage in
            if newImage != nil {
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
