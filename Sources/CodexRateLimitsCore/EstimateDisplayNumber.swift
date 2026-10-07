import Foundation

enum EstimateDisplayNumber {
    static func number(_ amount: Double) -> NSNumber {
        // Aggregation order can put the same estimate on either side of a cent
        // midpoint (92.415 +/- a few ULPs). Remove sub-display roundoff before
        // NumberFormatter rounds to cents. Keep raw estimates/cache untouched.
        var decimal = Decimal(amount)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, 10, .plain)
        // Decimal has a smaller exponent range than Double.
        return rounded.isNaN ? NSNumber(value: amount) : NSDecimalNumber(decimal: rounded)
    }
}
