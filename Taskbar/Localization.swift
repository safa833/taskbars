import Foundation

enum L10n {
    static func text(_ key: String, fallback: String) -> String {
        NSLocalizedString(
            key,
            tableName: nil,
            bundle: .main,
            value: fallback,
            comment: ""
        )
    }

    static func format(
        _ key: String,
        fallback: String,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: text(key, fallback: fallback),
            locale: Locale.current,
            arguments: arguments
        )
    }
}
