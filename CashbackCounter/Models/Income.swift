import Foundation
import SwiftData

@Model
class Income: Identifiable {
    var amount: Double
    var date: Date
    var currencyCode: String
    
    @Relationship(deleteRule: .nullify, inverse: \Transaction.incomes)
    var transaction: Transaction?
    
    init(amount: Double, date: Date, currencyCode: String, transaction: Transaction? = nil) {
        self.amount = amount
        self.date = date
        self.currencyCode = currencyCode
        self.transaction = transaction
    }
}
