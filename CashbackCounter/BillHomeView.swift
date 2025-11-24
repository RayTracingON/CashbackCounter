import SwiftUI
import SwiftData

struct BillHomeView: View {
    // 1. 拿到数据库上下文 (用来删除)
    @Environment(\.modelContext) var context
    
    @Query(sort: \Transaction.date, order: .reverse) var dbTransactions: [Transaction]
    
    // 2. 控制详情页弹窗
    @State private var selectedTransaction: Transaction? = nil
    
    // 3. 控制编辑页弹窗
    @State private var transactionToEdit: Transaction?
    
    // 计算总支出
    var totalExpense: Double {
        dbTransactions.reduce(0) { $0 + $1.amount }
    }
    
    // 计算总返现
    var totalCashback: Double {
        dbTransactions.reduce(0) {
            $0 + CashbackService.calculateCashback(for: $1)
        }
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) {
                        
                        // --- 统计条 ---
                        HStack(spacing: 15) {
                            StatBox(
                                title: "本月支出",
                                amount: "¥\(String(format: "%.2f", totalExpense))",
                                icon: "arrow.down.circle.fill",
                                color: .red
                            )
                            
                            StatBox(
                                title: "累计返现",
                                amount: "¥\(String(format: "%.2f", totalCashback))",
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
                            ForEach(dbTransactions) { item in
                                TransactionRow(transaction: item)
                                    // 1. 单击 -> 查看详情
                                    .onTapGesture {
                                        selectedTransaction = item
                                    }
                                    // 2. 长按 -> 弹出菜单
                                    .contextMenu {
                                        Button {
                                            // 赋值给 transactionToEdit，触发编辑弹窗
                                            transactionToEdit = item
                                        } label: {
                                            Label("编辑", systemImage: "pencil")
                                        }
                                        
                                        Button(role: .destructive) {
                                            // 直接删除
                                            context.delete(item)
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .navigationTitle("Cashback Counter")
            .navigationBarTitleDisplayMode(.inline)
            
            // 弹窗 1: 详情页
            .sheet(item: $selectedTransaction) { item in
                TransactionDetailView(transaction: item)
                    .presentationDetents([.large]) // iOS 16+
            }
            
            // 弹窗 2: 编辑页 (复用 AddTransactionView)
            .sheet(item: $transactionToEdit) { item in
                // 这里传入 transaction，让它进入编辑模式
                AddTransactionView(transaction: item)
            }
        }
    }
}
