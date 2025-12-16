import Foundation
import SwiftData

@Model
class Income: Identifiable {
    var amount: Double
    var date: Date
    var location: Region
    var detail : String
    var platform : String
    
    @Relationship(deleteRule: .nullify)
    var transaction: Transaction?
    
    init(amount: Double, date: Date, location: Region, transaction: Transaction? = nil, detail: String = "",platform : String = "") {
        self.amount = amount
        self.date = date
        self.location = location
        self.transaction = transaction
        self.detail = detail
        self.platform = platform
    }
    var dateString: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd" // 你可以改成 "yyyy-MM-dd" 或 "MM月dd日"
            return formatter.string(from: date)
        }
}
