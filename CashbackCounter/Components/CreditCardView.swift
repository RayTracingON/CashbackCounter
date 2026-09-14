//
//  CreditCardView.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/23/25.
//

import SwiftUI

struct CreditCardView: View {
    var bankName: String
    var type: String
    var endNum: String
    var colors: [Color]
    var cardImageData: Data? = nil
    
    // ✅ 新增：用于存储解码后图片的 State
    @State private var decodedImage: UIImage? = nil
    
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                // 1. 背景渐变
                LinearGradient(gradient: Gradient(colors: colors), startPoint: .topLeading, endPoint: .bottomTrailing)
                
                // 2. 装饰纹理
                Circle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 200, height: DesignConstants.CardList.cardHeight)
                    .offset(x: 150, y: -50)
                
                // 3. 图片层（✅ 修改：使用异步解码后的 State）
                if let uiImage = decodedImage {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: DesignConstants.CardList.cardHeight)
                        // ✅ 关键修复：限制图片最大宽度，防止宽图撑爆布局导致 GeometryReader 坐标错乱
                        .frame(maxWidth: proxy.size.width)
                        .clipped()
                        // 加一层极淡的黑罩，确保白色卡号稍微清晰点，又不影响卡面美观
                        .overlay(Color.black.opacity(0.05))
                }
                
                // 4. 文字信息层
                VStack(alignment: .leading) {
                    if cardImageData == nil {
                        HStack {
                            Image(systemName: "wave.3.right") // 非接触支付图标
                                .font(.title2)
                            Spacer()
                            Text(bankName + " " + type)
                                .font(.caption)
                                .fontWeight(.bold)
                                .padding(6)
                                .background(.ultraThinMaterial)
                                .cornerRadius(5)
                        }
                    }
                    Spacer()
                    HStack {
                        Text("**** **** **** \(endNum)")
                            .font(.subheadline)
                    }
                }
                .padding(25)
                .foregroundColor(.white)
            }
        }
        .frame(height: DesignConstants.CardList.cardHeight)
        .cornerRadius(20)
        .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
        .padding(.horizontal)
        // ✅ 核心修复：在后台线程处理图片解码，避免阻塞主线程
        .task(id: cardImageData) {
            if let data = cardImageData {
                // 使用 detached 任务避免继承当前上下文的优先级，确保不卡顿 UI
                let image = await Task.detached(priority: .userInitiated) {
                    return UIImage(data: data)
                }.value
                
                // 回到主线程更新 UI
                await MainActor.run {
                    withAnimation(.easeIn(duration: 0.2)) {
                        self.decodedImage = image
                    }
                }
            } else {
                self.decodedImage = nil
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("卡面 · 渐变", traits: .sizeThatFitsLayout) {
    VStack(spacing: 16) {
        ForEach(PreviewData.cards) { card in
            CreditCardView(bankName: card.bankName,
                           type: card.type,
                           endNum: card.endNum,
                           colors: card.colors)
                .frame(height: DesignConstants.CardList.cardHeight)
        }
    }
    .padding()
    .previewEnvironment()
}

#Preview("卡面 · 自定义图片", traits: .sizeThatFitsLayout) {
    // 传了 cardImageData 就走图片分支，渐变和装饰纹理都不该再出现
    CreditCardView(bankName: "招商银行",
                   type: "经典白金卡",
                   endNum: "6688",
                   colors: [.blue, .purple],
                   cardImageData: PreviewData.cardArtData)
        .frame(height: DesignConstants.CardList.cardHeight)
        .padding()
}

#Preview("卡面 · 极端文案", traits: .sizeThatFitsLayout) {
    // 超长银行名 + 空卡号：验证不会撑破卡片
    CreditCardView(bankName: "中国银行（香港）有限公司",
                   type: "双币种世界之极尊享白金卡",
                   endNum: "",
                   colors: [Color(hex: "9C1B24"), Color(hex: "D94F45")])
        .frame(height: DesignConstants.CardList.cardHeight)
        .padding()
}
#endif
