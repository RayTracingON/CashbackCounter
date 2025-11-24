//
//  Category.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/23/25.
//
import FoundationModels
import Foundation
import SwiftUI

@Generable
enum Category: String, CaseIterable, Codable {
    // 定义所有的类别 (Key)
    case dining     // 餐饮
    case grocery    // 超市
    case travel     // 出行
    case digital    // 数码
    case other      // 其他
    
    // 计算属性：专门负责返回对应的图标
    var iconName: String {
        switch self {
        case .dining: return "cup.and.saucer.fill"
        case .grocery: return "cart.fill"
        case .travel: return "car.fill"
        case .digital: return "laptopcomputer.and.iphone"
        case .other: return "creditcard"
        }
    }
    
    // 计算属性：返回给人看的中文名
    var displayName: String {
        switch self {
        case .dining: return "餐饮美食"
        case .grocery: return "超市便利"
        case .travel: return "交通出行"
        case .digital: return "数码产品"
        case .other: return "其他消费"
        }
    }
    var color: Color {
            switch self {
            case .dining: return .orange
            case .digital: return .gray
            case .grocery: return .green
            case .travel: return .purple
            case .other: return .red
            }
        }
}
