import Foundation
import SwiftUI

@MainActor
final class AppleIntelligenceAvailability: ObservableObject {
    @Published private(set) var isSupported: Bool = false
    @Published var showCompatibilityAlert: Bool = false

    func refreshSupportStatus() {
        let supported: Bool
        if #available(iOS 18.0, *) {
            supported = true
        } else {
            supported = false
        }

        isSupported = supported
        showCompatibilityAlert = !supported
    }
}
