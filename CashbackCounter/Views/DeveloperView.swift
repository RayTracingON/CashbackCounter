//
//  DeveloperView.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 12/3/25.
//

import SwiftUI

struct DeveloperView: View {

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack(spacing: 16) {
                        // Avatar placeholder
                        ZStack {
                            Circle()
                                .fill(Color.blue.opacity(0.15))
                                .frame(width: 64, height: 64)
                            Image(systemName: "person.crop.circle.fill")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 56, height: 56)
                                .foregroundColor(.blue)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("RTXON")
                                .font(.headline)
                            Text("开发者")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    HStack(spacing: 16) {
                        // Avatar placeholder
                        ZStack {
                            Circle()
                                .fill(Color.blue.opacity(0.15))
                                .frame(width: 64, height: 64)
                            Image(systemName: "person.crop.circle.fill")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 56, height: 56)
                                .foregroundColor(.blue)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Mr.")
                                .font(.headline)
                            Text("贡献者")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    HStack(spacing: 16) {
                        // Avatar placeholder
                        ZStack {
                            Circle()
                                .fill(Color.blue.opacity(0.15))
                                .frame(width: 64, height: 64)
                            Image(systemName: "person.crop.circle.fill")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 56, height: 56)
                                .foregroundColor(.blue)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("xunzihao")
                                .font(.headline)
                            Text("贡献者")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section(header: Text("项目")) {
                    Link(destination: AppConfig.githubRepoURL) {
                        Label("Cashback Counter 仓库", systemImage: "shippingbox")
                    }
                }

                Section(header: Text("致谢")) {
                    Link(destination: AppConfig.cardentifyRepoURL) {
                        Label("调用卡面库 Cardentify", systemImage: "shippingbox")
                    }
                    Link(destination: AppConfig.exchangeAPIRepoURL) {
                        Label("调用货币费率数据库 exchange-api", systemImage: "shippingbox")
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("关于开发者") {
    DeveloperView()
}

#Preview("关于开发者 · 深色") {
    DeveloperView()
        .preferredColorScheme(.dark)
}
#endif
