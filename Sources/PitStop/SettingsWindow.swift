import AppKit
import ServiceManagement
import SwiftUI

/// PitStop's preferences, bound to UserDefaults via `@AppStorage`. AppDelegate
/// watches the same keys (`Settings.observedKeys`) and refreshes the menu bar
/// and menu when any of them change.
struct SettingsView: View {
    @AppStorage("indicatorStyle") private var style: IndicatorStyle = .iconAndPercent
    @AppStorage("indicatorMetric") private var metric: IndicatorMetric = .binding
    @AppStorage("menuBarSource") private var menuBarSource: MenuBarSource = .activeClaudeCode
    @AppStorage("autoSwitchEnabled") private var autoSwitch = false
    @AppStorage("autoSwitchThreshold") private var threshold = 90
    @AppStorage("showProjection") private var showProjection = true

    var body: some View {
        Form {
            Section("Menu Bar") {
                Picker("Show", selection: $style) {
                    ForEach(IndicatorStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Track", selection: $menuBarSource) {
                    ForEach(MenuBarSource.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Number from", selection: $metric) {
                    ForEach(IndicatorMetric.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .disabled(menuBarSource != .activeClaudeCode)
            }

            Section("Auto-switch") {
                Toggle("Auto-switch when an account runs low", isOn: $autoSwitch)
                if autoSwitch {
                    Stepper("Switch at \(threshold)% used", value: $threshold, in: 50 ... 99, step: 5)
                }
                Text("Flips the live Claude Code account to the saved account with the most headroom, and notifies you. Codex and Desktop are left alone.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Usage") {
                Toggle("Show time-to-limit projection", isOn: $showProjection)
                Text("Estimates when a window will hit 100% at your recent pace, shown only when that's before it resets.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                LaunchAtLoginToggle()
            }
        }
        .formStyle(.grouped)
        .frame(width: 430)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Launch-at-login lives in `SMAppService`, not UserDefaults, so it gets its
/// own toggle that registers/unregisters the login item.
private struct LaunchAtLoginToggle: View {
    @State private var on = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Launch at login", isOn: Binding(
            get: { on },
            set: { want in
                try? want ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                on = SMAppService.mainApp.status == .enabled
            }))
    }
}

/// Owns the (lazily created) settings window so it survives close and reopens.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let w = NSWindow(contentViewController: hosting)
            w.title = "PitStop Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        // Accessory app: bring it forward and give the window focus without
        // adding a Dock icon.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
