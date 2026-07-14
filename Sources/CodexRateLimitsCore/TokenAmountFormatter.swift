import Foundation

public enum TokenAmountFormatter {
    private enum UnitSystem {
        case simplifiedChinese
        case traditionalChinese
        case japanese
        case korean
        case western
    }

    public static func compact(
        _ tokens: Int64,
        maximumFractionDigits: Int = 2,
        locale: Locale = .autoupdatingCurrent,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        switch unitSystem(locale: locale, preferredLanguages: preferredLanguages) {
        case .simplifiedChinese:
            return formatWanYi(tokens, tenThousandUnit: "万", hundredMillionUnit: "亿", maximumFractionDigits: maximumFractionDigits, locale: locale)
        case .traditionalChinese:
            return formatWanYi(tokens, tenThousandUnit: "萬", hundredMillionUnit: "億", maximumFractionDigits: maximumFractionDigits, locale: locale)
        case .japanese:
            return formatWanYi(tokens, tenThousandUnit: "万", hundredMillionUnit: "億", maximumFractionDigits: maximumFractionDigits, locale: locale)
        case .korean:
            return formatWanYi(tokens, tenThousandUnit: "만", hundredMillionUnit: "억", maximumFractionDigits: maximumFractionDigits, locale: locale)
        case .western:
            return formatWestern(tokens, maximumFractionDigits: maximumFractionDigits)
        }
    }

    private static func unitSystem(locale: Locale, preferredLanguages: [String]) -> UnitSystem {
        if let preferredLanguage = preferredLanguages.first.map(normalizedIdentifier), !preferredLanguage.isEmpty {
            return unitSystem(identifier: preferredLanguage) ?? .western
        }

        return unitSystem(identifier: normalizedIdentifier(locale.identifier)) ?? .western
    }

    private static func unitSystem(identifier: String) -> UnitSystem? {
        let components = identifier.split(separator: "-").map(String.init)
        guard let language = components.first else { return nil }
        switch language {
        case "ja":
            return .japanese
        case "ko":
            return .korean
        case "zh", "yue":
            return chineseUnitSystem(identifier: identifier)
        default:
            return nil
        }
    }

    private static func chineseUnitSystem(identifier: String) -> UnitSystem {
        if identifier.contains("-hant")
            || identifier.contains("-hk")
            || identifier.contains("-tw")
            || identifier.contains("-mo")
        {
            return .traditionalChinese
        }
        return .simplifiedChinese
    }

    private static func normalizedIdentifier(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }

    private static func formatWanYi(
        _ tokens: Int64,
        tenThousandUnit: String,
        hundredMillionUnit: String,
        maximumFractionDigits: Int,
        locale: Locale
    ) -> String {
        let absoluteTokens = abs(tokens)
        let value = Double(tokens)
        if absoluteTokens >= 100_000_000 {
            return "\(formatNumber(value / 100_000_000, maximumFractionDigits: maximumFractionDigits, locale: locale))\(hundredMillionUnit)"
        }
        if absoluteTokens >= 10_000 {
            return "\(formatNumber(value / 10_000, maximumFractionDigits: maximumFractionDigits, locale: locale))\(tenThousandUnit)"
        }
        return formatInteger(tokens)
    }

    private static func formatWestern(_ tokens: Int64, maximumFractionDigits: Int) -> String {
        let absoluteTokens = abs(tokens)
        let value = Double(tokens)
        let scales: [(threshold: Int64, divisor: Double, unit: String)] = [
            (1_000_000_000_000, 1_000_000_000_000, "T"),
            (1_000_000_000, 1_000_000_000, "B"),
            (1_000_000, 1_000_000, "M"),
            (1_000, 1_000, "K"),
        ]

        for scale in scales where absoluteTokens >= scale.threshold {
            return "\(formatNumber(value / scale.divisor, maximumFractionDigits: maximumFractionDigits, locale: Locale(identifier: "en_US_POSIX")))\(scale.unit)"
        }
        return formatInteger(tokens)
    }

    private static func formatNumber(_ value: Double, maximumFractionDigits: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        formatter.numberStyle = .decimal
        formatter.roundingMode = .halfUp
        if let formatted = formatter.string(from: NSNumber(value: value)) {
            return formatted
        }
        return String(format: "%.\(maximumFractionDigits)f", value)
    }

    private static func formatInteger(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
