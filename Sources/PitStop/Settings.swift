import Foundation

/// What the menu bar number tracks.
enum MenuBarSource: String, CaseIterable {
    /// The Claude Code account you're currently logged into (default).
    case activeClaudeCode
    /// Whichever account — any provider — is closest to its limit.
    case mostUrgent

    var label: String {
        switch self {
        case .activeClaudeCode: return "Active Claude Code account"
        case .mostUrgent: return "Most-used account (any provider)"
        }
    }
}

/// Typed access to the user's preferences (UserDefaults). The settings window
/// binds the same keys via `@AppStorage`; AppDelegate reads them here and
/// reacts to changes via KVO on `observedKeys`.
enum Settings {
    static var menuBarSource: MenuBarSource {
        UserDefaults.standard.string(forKey: "menuBarSource")
            .flatMap(MenuBarSource.init) ?? .activeClaudeCode
    }

    /// Auto-switch the active Claude Code account to the emptiest alternative
    /// when it crosses the threshold. Off by default — it's a surprising action.
    static var autoSwitchEnabled: Bool {
        UserDefaults.standard.bool(forKey: "autoSwitchEnabled")
    }

    /// Utilization (%) at which auto-switch kicks in. Default 90.
    static var autoSwitchThreshold: Int {
        let v = UserDefaults.standard.integer(forKey: "autoSwitchThreshold")
        return v == 0 ? 90 : v
    }

    /// Show a "≈ full HH:MM at this pace" projection on rows trending toward a
    /// limit. On by default; only renders when the trend is meaningful.
    static var showProjection: Bool {
        UserDefaults.standard.object(forKey: "showProjection") == nil
            ? true : UserDefaults.standard.bool(forKey: "showProjection")
    }

    /// Keys AppDelegate watches to refresh the UI when settings change.
    static let observedKeys = [
        "indicatorStyle", "indicatorMetric", "menuBarSource",
        "autoSwitchEnabled", "autoSwitchThreshold", "showProjection",
    ]
}
