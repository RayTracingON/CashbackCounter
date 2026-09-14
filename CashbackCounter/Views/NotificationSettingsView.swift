import SwiftUI
import SwiftData

struct NotificationSettingsView: View {
    @Query var cards: [CreditCard]
    
    var body: some View {
        List {
            Section(footer: Text("开启后，将在每月还款日上午 9:00 推送提醒。")) {
                if cards.isEmpty {
                    Text("暂无卡片，请先添加信用卡")
                        .foregroundColor(.secondary)
                }
                
                ForEach(cards) { card in
                    HStack {
                        // 左侧信息
                        VStack(alignment: .leading) {
                            Text("\(card.bankName) \(card.type)")
                                .font(.headline)
                            if card.repaymentDay > 0 {
                                Text("每月 \(card.repaymentDay) 日还款")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("未设置还款日")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                        
                        Spacer()
                        
                        // 右侧开关
                        Toggle("", isOn: Binding(
                            get: { card.isRemindOpen },
                            set: { newValue in
                                card.isRemindOpen = newValue
                                // 👇 核心：开关变动时，立刻刷新通知状态
                                if newValue {
                                    NotificationManager.shared.scheduleNotification(for: card)
                                } else {
                                    NotificationManager.shared.cancelNotification(for: card)
                                }
                            }
                        ))
                        // 如果没设置还款日，禁用开关并提示
                        .disabled(card.repaymentDay == 0)
                    }
                }
            }
        }
        .navigationTitle("还款提醒")
        .onAppear {
            // 进页面时检查一下权限
            NotificationManager.shared.requestAuthorization()
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("还款提醒") {
    NavigationStack {
        NotificationSettingsView()
    }
    .previewEnvironment()
}

#Preview("还款提醒 · 无卡片") {
    NavigationStack {
        NotificationSettingsView()
    }
    .previewEmptyEnvironment()
}
#endif
