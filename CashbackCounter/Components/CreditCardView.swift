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
    
    var body: some View {
        ZStack(alignment: .leading) {
            LinearGradient(gradient: Gradient(colors: colors), startPoint: .topLeading, endPoint: .bottomTrailing)
            
            // 装饰纹理
            Circle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 200, height: 200)
                .offset(x: 150, y: -50)
            
            VStack(alignment: .leading) {
                HStack {
                    Image(systemName: "wave.3.right") // 非接触支付图标
                        .font(.title2)
                    Spacer()
                    Text(bankName+" "+type)
                        .font(.caption)
                        .fontWeight(.bold)
                        .padding(6)
                        .background(.ultraThinMaterial)
                        .cornerRadius(5)
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
        .frame(height: 200)
        .cornerRadius(20)
        .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
        .padding(.horizontal)
    }
}
