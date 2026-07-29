//
//  PaywallView.swift
//  CashbackCounter
//
//  付费墙。只挡银行同步 —— 手动记账、卡包、费率/上限引擎、还款提醒、
//  拍照记账、账单分析全部免费，老用户一点不受影响。
//
//  按路线图的原则：**拦在发起动作处，而不是把入口藏起来**。
//  用户看得见功能存在才谈得上转化；藏起来的功能等于不存在。
//

import StoreKit
import SwiftUI

struct PaywallView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var subscriptions = SubscriptionManager.shared

    @State private var selected: Product?
    @State private var errorMessage: String?

    /// 订阅成功后的回调，调用方拿它继续原本要做的事
    var onSubscribed: (() -> Void)?

    init(onSubscribed: (() -> Void)? = nil) {
        self.onSubscribed = onSubscribed
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    header
                    benefits
                    planPicker

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    subscribeButton
                    restoreAndTerms
                }
                .padding(.vertical, 20)
            }
            .navigationTitle("银行自动同步")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task {
                if subscriptions.products.isEmpty {
                    await subscriptions.loadProducts()
                }
                selected = selected ?? subscriptions.products.last
            }
        }
    }

    // MARK: - 子视图

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "building.columns.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.blue)

            Text("让交易自己进来")
                .font(.title2.bold())

            Text("绑定银行后，信用卡和借记卡的消费会自动同步，并按你设置的费率算好返现与积分。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 14) {
            benefit("building.columns", "绑定美国银行", "信用卡与活期账户都支持，可绑多家")
            benefit("arrow.triangle.2.circlepath", "交易自动同步", "每天自动导入，也可随时手动刷新")
            benefit("bell.badge", "新交易通知", "银行一有新交易就推送提醒")
            benefit("arrow.uturn.backward", "退款自动抵销", "退款会自动冲掉原来那笔，返现跟着回冲")
        }
        .padding(.horizontal, 32)
    }

    /// 同 AccountView.privacyRow：必须是 LocalizedStringKey，
    /// `Text(String)` 不会本地化
    private func benefit(_ icon: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var planPicker: some View {
        if subscriptions.isLoadingProducts && subscriptions.products.isEmpty {
            ProgressView().padding()
        } else if subscriptions.products.isEmpty {
            // 产品拉不到最常见的原因是 App Store Connect 里还没配好，
            // 或者本地没挂 StoreKit Configuration 文件
            Text("暂时无法获取订阅选项，请稍后再试。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding()
        } else {
            VStack(spacing: 10) {
                ForEach(subscriptions.products, id: \.id) { product in
                    planRow(product)
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func planRow(_ product: Product) -> some View {
        let isSelected = selected?.id == product.id

        return Button {
            selected = product
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(product.displayName.isEmpty ? product.id : product.displayName)
                        .font(.body.weight(.medium))
                    if !product.description.isEmpty {
                        Text(product.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(product.displayPrice)
                    .font(.body.weight(.semibold))
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.blue : Color.secondary.opacity(0.3),
                            lineWidth: isSelected ? 2 : 1))
        }
        .tint(.primary)
    }

    private var subscribeButton: some View {
        Button {
            Task { await subscribe() }
        } label: {
            if subscriptions.isPurchasing {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Text("订阅").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.horizontal, 24)
        .disabled(selected == nil || subscriptions.isPurchasing)
    }

    private var restoreAndTerms: some View {
        VStack(spacing: 10) {
            // 恢复购买是 App Store 审核的硬要求，不能只在设置页里有
            Button("恢复购买") {
                Task { await subscriptions.restore(); dismissIfSubscribed() }
            }
            .font(.footnote)

            Text("订阅会自动续期，可随时在系统「设置 → Apple 账户 → 订阅」中取消。取消需在当前周期结束前 24 小时完成。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    // MARK: - 动作

    private func subscribe() async {
        guard let selected else { return }
        errorMessage = nil

        do {
            let success = try await subscriptions.purchase(selected)
            if success {
                onSubscribed?()
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func dismissIfSubscribed() {
        if subscriptions.isPremium {
            onSubscribed?()
            dismiss()
        }
    }
}
