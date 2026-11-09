import SwiftUI
import AppKit

@main
struct Entry {
    static func main() {
        if ShortcutMaker.runIfLauncher() { exit(0) }
        if CLI.handle(CommandLine.arguments) { exit(0) }
        carryOverSettings()
        RelaycatApp.main()
    }

    // Relaycat used to be called Switchyard, with a different bundle ID. Keep the choices people made there.
    static func carryOverSettings() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "carriedOverSettings"), let old = UserDefaults(suiteName: "app.switchyard.mac") else { return }
        for k in ["hideAccessNotice", "hideGraftNotice", "liveLimits", "openAfterSwitch", "quitPolicy", "showInspector", "showMenuBar"]
        where d.object(forKey: k) == nil {
            if let v = old.object(forKey: k) { d.set(v, forKey: k) }
        }
        d.set(true, forKey: "carriedOverSettings")
    }
}

struct RelaycatApp: App {
    @StateObject private var model = AppModel.shared
    @AppStorage("showMenuBar") private var showMenuBar = true

    var body: some Scene {
        Window("Relaycat", id: "main") {
            RootView()
                .environmentObject(model)
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Check again") { model.refresh() }.keyboardShortcut("r")
                Divider()
                ForEach(Array(Page.allCases.enumerated()), id: \.offset) { i, p in
                    Button(p.title) { model.sidebar = .page(p) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
            }
        }

        Settings {
            SettingsView().environmentObject(model)
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarPanel().environmentObject(model)
        } label: {
            MenuBarLabel().environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct SettingsView: View {
    @EnvironmentObject var m: AppModel
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("mochiWanders") private var mochiWanders = true

    var body: some View {
        Form {
            Section {
                Picker("When Claude asks “Quit anyway?”", selection: $m.quitPolicyRaw) {
                    Text("Quit anyway").tag(QuitPolicy.quitAnyway.rawValue)
                    Text("Let me answer in Claude").tag(QuitPolicy.askMe.rawValue)
                }
                .pickerStyle(.radioGroup)
                LabeledContent("Accessibility access") {
                    if m.hasAccess {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        HStack {
                            Button("Allowed already? Fix it") { m.resetAccess() }.buttonStyle(.link)
                            Button("Allow…") { m.askForAccess() }
                        }
                    }
                }
            } header: {
                Text("Closing Claude")
            } footer: {
                Text(m.hasAccess
                     ? "Relaycat presses “Quit anyway” for you, the same as clicking it yourself."
                     : "With access, Relaycat presses “Quit anyway” for you. Without it, Relaycat waits a few seconds and then closes Claude by force, which also stops its background commands.")
                    .foregroundStyle(.secondary)
            }

            Section("Switching") {
                Toggle("Open the profile after switching", isOn: $m.openAfterSwitch)
                Toggle("Show Relaycat in the menu bar", isOn: $showMenuBar)
                Toggle("Let Mochi wander around now and then", isOn: $mochiWanders)
            }

            Section {
                Toggle("Get live limits from Anthropic", isOn: Binding(get: { m.liveLimits }, set: { on in
                    if on { m.turnOnLiveLimits() } else { m.liveLimits = false }
                }))
                if m.liveLimits {
                    LabeledContent("Last checked") {
                        HStack(spacing: 8) {
                            Text(m.snap?.limitsCheckedAt.map { Fmt.ago($0) } ?? "Not yet")
                            if m.checkingLimits { ProgressView().controlSize(.small) }
                            else { Button("Check now") { m.refreshLimits(force: true, allowPrompt: true) } }
                        }
                    }
                }
            } header: {
                Text("Limits")
            } footer: {
                Text("Relaycat reads each profile's own saved login, the same way the Claude app does, and asks Anthropic for its limits. macOS asks once whether Relaycat may use “Claude Safe Storage”: choose Always Allow. The login is only read, never renewed, so no Claude gets signed out.")
                    .foregroundStyle(.secondary)
            }

            if ProfileAdmin.graftInstalled {
                Section {
                    LabeledContent("Claude Graft") {
                        Text(m.graftRunning ? "Running" : "Not running").foregroundStyle(.secondary)
                    }
                    Button("Stop using Claude Graft…") { m.takingOver = true }
                } footer: {
                    Text("Relaycat now does what Claude Graft did: profile apps, new profiles and limits. Moving off rebuilds your profile apps and closes Claude Graft.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
