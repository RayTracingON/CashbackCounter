import SwiftUI

struct ReceiptFullScreenView: View {
    let image: UIImage
    @Environment(\.dismiss) var dismiss
    
    // 控制缩放比例
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    var body: some View {
        ZStack {
            // 1. 黑色背景
            Color.black.ignoresSafeArea()
            
            // 2. 图片
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    // 双指缩放手势
                    MagnificationGesture()
                        .onChanged { value in
                            let delta = value / lastScale
                            lastScale = value
                            scale *= delta
                        }
                        .onEnded { _ in
                            lastScale = 1.0
                            // 缩放结束后，如果小于 1 倍，自动弹回 1 倍
                            withAnimation {
                                if scale < 1.0 {
                                    scale = 1.0
                                    offset = .zero
                                }
                            }
                        }
                )
                // 双击复原
                .onTapGesture(count: 2) {
                    withAnimation {
                        scale = 1.0
                        offset = .zero
                    }
                }
            
            // 3. 关闭按钮 (右上角)
            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        dismiss()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.black.opacity(0.8))
                            .padding()
                    }
                }
                Spacer()
            }
        }
    }
}
