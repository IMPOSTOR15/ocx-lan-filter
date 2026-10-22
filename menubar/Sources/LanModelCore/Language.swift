import Foundation

public enum AppLanguage: String, Sendable {
    case ru, en
}

/// What the user picked in Settings. `system` follows the macOS language: Russian only when it is the
/// primary preferred language, English in every other case.
public enum LanguagePreference: String, CaseIterable, Sendable {
    case system, ru, en

    public static let defaultsKey = "appLanguage"

    public func resolve(preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        switch self {
        case .ru: return .ru
        case .en: return .en
        case .system:
            let first = preferred.first?.lowercased() ?? ""
            return first == "ru" || first.hasPrefix("ru-") || first.hasPrefix("ru_") ? .ru : .en
        }
    }

    public static func stored(in defaults: UserDefaults = .standard) -> LanguagePreference {
        defaults.string(forKey: defaultsKey).flatMap(LanguagePreference.init(rawValue:)) ?? .system
    }

    public func store(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
