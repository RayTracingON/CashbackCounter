import SwiftUI

struct BillHomeView: View {
    @EnvironmentObject var manager: DataManager
    
    // --- 1. 自动计算总支出 ---
    // reduce 是一个高阶函数：把数组里的每一项 ($1) 的 amount 加到初始值 0 ($0) 上
    var totalExpense: Double {
        manager.transactions.reduce(0) { $0 + $1.amount }
    }
    
    // --- 2. 自动计算总返现 ---
    var totalCashback: Double {
            manager.transactions.reduce(0) { currentTotal, transaction in
                // 每一笔都问 manager 算一下返现，然后加起来
                currentTotal + manager.getCashback(for: transaction)
            }
        }
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) {
                        
                        // --- 3. 消失的统计条 (这里加回来了！) ---
                        // 而且现在它是动态的，数字会随着你记账自动变！
                        HStack(spacing: 15) {
                            StatBox(
                                title: "本月支出",
                                amount: "¥\(String(format: "%.2f", totalExpense))", // 显示真数据
                                icon: "arrow.down.circle.fill",
                                color: .red
                            )
                            
                            StatBox(
                                title: "累计返现",
                                amount: "¥\(String(format: "%.2f", totalCashback))", // 显示真数据
                                icon: "arrow.up.circle.fill",
                                color: .green
                            )
                        }
                        .padding(.horizontal)
                        .padding(.top)
                        
                        // --- 列表标题 ---
                        HStack {
                            Text("近期账单")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal)
                        
                        // --- 交易列表 ---
                        LazyVStack(spacing: 15) {
                            ForEach(manager.transactions) { item in
                                TransactionRow(transaction: item)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .navigationTitle("Cashback Counter")
            .navigationBarTitleDisplayMode(.inline)
        
        }
    }
}

// 别忘了给预览也加假数据，不然预览会崩
#Preview {
    BillHomeView()
        .environmentObject(DataManager())
}
