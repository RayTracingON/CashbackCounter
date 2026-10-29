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
    /// 按卡面图上卡号那块背景选出的文字颜色；和图片一起在后台算好，nil 表示退回看渐变
    @State private var imageInk: CardTextContrast.Ink? = nil
    @Environment(\.self) private var environment
    
    /// 文字用白字还是黑字：有卡面图看图，否则看渐变（规则见 CardTextContrast）
    private var ink: CardTextContrast.Ink {
        if decodedImage != nil, let imageInk { return imageInk }
        return CardTextContrast.ink(gradient: colors.map { color in
            let resolved = color.resolve(in: environment)
            return SIMD3(Double(resolved.red), Double(resolved.green), Double(resolved.blue))
        })
    }
    
    var body: some View {
        let ink = self.ink
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                // 1. 背景渐变
                LinearGradient(gradient: Gradient(colors: colors), startPoint: .topLeading, endPoint: .bottomTrailing)
                
                // 2. 装饰纹理
                Circle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 200, height: proxy.size.height)
                    .offset(x: 150, y: -50)

                // 3. 图片层（✅ 修改：使用异步解码后的 State）
                if let uiImage = decodedImage {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: proxy.size.height)
                        // ✅ 关键修复：限制图片最大宽度，防止宽图撑爆布局导致 GeometryReader 坐标错乱
                        .frame(maxWidth: proxy.size.width)
                        .clipped()
                        // 白字时加一层极淡的黑罩，让卡号稍微清晰点，又不影响卡面美观；黑字时不需要
                        .overlay(Color.black.opacity(ink == .light ? 0.05 : 0))
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
                // 浅色卡面（白金、金卡、Apple Card…）上白字看不清，按背景自动切黑字
                .foregroundColor(ink == .dark ? .black : .white)
            }
        }
        // 高度跟着拿到的宽度按银行卡比例走：卡包列表、iPad 上的添加卡片 sheet 宽度各不相同，
        // 写死高度会把卡面拉扁或拉长
        .aspectRatio(DesignConstants.CardList.aspectRatio, contentMode: .fit)
        .cornerRadius(20)
        .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
        .padding(.horizontal)
        // ✅ 核心修复：在后台线程处理图片解码，避免阻塞主线程
        .task(id: cardImageData) {
            if let data = cardImageData {
                // 使用 detached 任务避免继承当前上下文的优先级，确保不卡顿 UI；
                // 卡号该用白字还是黑字要看图上那块区域的亮度，顺手在同一个后台任务里算掉
                let (image, imageInk) = await Task.detached(priority: .userInitiated) {
                    let image = UIImage(data: data)
                    return (image, image.flatMap { CardTextContrast.ink(cardImage: $0) })
                }.value
                
                // 回到主线程更新 UI
                await MainActor.run {
                    withAnimation(.easeIn(duration: 0.2)) {
                        self.decodedImage = image
                        self.imageInk = imageInk
                    }
                }
            } else {
                self.decodedImage = nil
                self.imageInk = nil
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
        .padding()
}

#Preview("卡面 · 浅色自动黑字", traits: .sizeThatFitsLayout) {
    // Apple Card / AMEX Gold 的实卡原色应切成黑字；Sapphire Reserve 这种深色仍是白字
    VStack(spacing: 16) {
        CreditCardView(bankName: "Apple", type: "Card", endNum: "0001",
                       colors: [Color(hex: "F5F5F7"), Color(hex: "F8D347")])
        CreditCardView(bankName: "AMEX US", type: "Gold", endNum: "1005",
                       colors: [Color(hex: "A39458"), Color(hex: "E0CA79")])
        CreditCardView(bankName: "Chase", type: "Sapphire Reserve", endNum: "2077",
                       colors: [Color(hex: "12141C"), Color(hex: "6E6555")])
    }
    .padding()
}

#Preview("卡面 · 极端文案", traits: .sizeThatFitsLayout) {
    // 超长银行名 + 空卡号：验证不会撑破卡片
    CreditCardView(bankName: "中国银行（香港）有限公司",
                   type: "双币种世界之极尊享白金卡",
                   endNum: "",
                   colors: [Color(hex: "9C1B24"), Color(hex: "D94F45")])
        .padding()
}
#endif
