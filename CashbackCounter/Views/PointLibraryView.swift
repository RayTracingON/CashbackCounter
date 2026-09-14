import SwiftUI
import SwiftData

struct PointLibraryView: View {
    @Environment(\.modelContext) var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\Point.bankName, order: .forward)])
    private var points: [Point]

    @State private var pointToEdit: Point?
    @State private var showAddSheet = false

    var body: some View {
        NavigationView {
            List {
                if points.isEmpty {
                    ContentUnavailableView(
                        "暂无积分库",
                        systemImage: "star.circle",
                        description: Text("请添加积分计划以供卡片选择")
                    )
                } else {
                    ForEach(points) { point in
                        Button {
                            pointToEdit = point
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(point.displayName)
                                    .font(.headline)
                                Text("价值: \(String(format: "%.6f", point.pointValue)) \(point.valueCurrencyCode.currencyCode) / 点")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            let point = points[index]
                            context.delete(point)
                        }
                    }
                }
            }
            .navigationTitle("积分库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                PointEditorView()
            }
            .sheet(item: $pointToEdit) { point in
                PointEditorView(pointToEdit: point)
            }
        }
    }
}

struct PointEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var pointToEdit: Point?

    @State private var bankName: String
    @State private var pointName: String
    @State private var pointValueStr: String
    @State private var currencyRegion: Region
    @State private var isActive: Bool
    @State private var note: String

    init(pointToEdit: Point? = nil) {
        self.pointToEdit = pointToEdit
        if let point = pointToEdit {
            _bankName = State(initialValue: point.bankName)
            _pointName = State(initialValue: point.pointName)
            _pointValueStr = State(initialValue: String(point.pointValue))
            _currencyRegion = State(initialValue: point.valueCurrencyCode)
            _isActive = State(initialValue: point.isActive)
            _note = State(initialValue: point.note)
        } else {
            _bankName = State(initialValue: "")
            _pointName = State(initialValue: "")
            _pointValueStr = State(initialValue: "0.01")
            _currencyRegion = State(initialValue: .cn)
            _isActive = State(initialValue: true)
            _note = State(initialValue: "")
        }
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("基本信息")) {
                    TextField("银行", text: $bankName)
                    TextField("积分名称", text: $pointName)
                }

                Section(header: Text("价值与币种")) {
                    HStack {
                        Text("积分价值")
                        Spacer()
                        TextField("0.01", text: $pointValueStr)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("币种", selection: $currencyRegion) {
                        ForEach(Region.allCases, id: \.self) { region in
                            Text("\(region.icon) \(region.currencyCode)")
                                .tag(region)
                        }
                    }
                }

                Section(header: Text("状态")) {
                    Toggle("启用中", isOn: $isActive)
                }

                Section(header: Text("备注")) {
                    TextField("例如：积分每年清零", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle(pointToEdit == nil ? "新增积分计划" : "编辑积分计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { savePoint() }
                        .disabled(bankName.isEmpty || pointName.isEmpty)
                }
            }
        }
    }

    private func savePoint() {
        let pointValue = Double(pointValueStr) ?? 0
        if let existing = pointToEdit {
            existing.bankName = bankName
            existing.pointName = pointName
            existing.pointValue = pointValue
            existing.valueCurrencyCode = currencyRegion
            existing.isActive = isActive
            existing.note = note
        } else {
            let newPoint = Point(
                bankName: bankName,
                pointName: pointName,
                pointValue: pointValue,
                valueCurrencyCode: currencyRegion,
                isActive: isActive,
                note: note
            )
            context.insert(newPoint)
        }

        dismiss()
    }
}

// MARK: - Previews

#if DEBUG
#Preview("积分库") {
    PointLibraryView()
        .previewEnvironment()
}

#Preview("积分库 · 空") {
    PointLibraryView()
        .previewEmptyEnvironment()
}

#Preview("新增积分计划") {
    PointEditorView()
        .previewEnvironment()
}

#Preview("编辑积分计划") {
    PointEditorView(pointToEdit: PreviewData.point)
        .previewEnvironment()
}
#endif
