import Foundation
import LanModelCore

/// Current UI language. Views re-render when `UIState.language` changes, and then read this again through `tr`.
enum Lang {
    nonisolated(unsafe) static var current: AppLanguage = LanguagePreference.stored().resolve()
}

func tr(_ ru: String, _ en: String) -> String {
    Lang.current == .ru ? ru : en
}
