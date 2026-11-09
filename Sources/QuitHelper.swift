import Foundation
import AppKit
import ApplicationServices

enum QuitPolicy: String, CaseIterable, Identifiable {
    case quitAnyway, askMe
    var id: String { rawValue }
    var label: String {
        switch self {
        case .quitAnyway: return "Always quit"
        case .askMe: return "Let me answer"
        }
    }
    static var current: QuitPolicy {
        QuitPolicy(rawValue: UserDefaults.standard.string(forKey: "quitPolicy") ?? "") ?? .quitAnyway
    }
}

struct QuitTarget { var name: String; var pids: [Int32] }

struct QuitReport {
    var closed: [String] = []
    var answeredPrompt: [String] = []
    var forced: [String] = []
}

enum QuitError: LocalizedError {
    case stillOpen([String])
    case cancelled(String)
    var errorDescription: String? {
        switch self {
        case .stillOpen(let n):
            return "\(n.joined(separator: " and ")) wouldn't close, so nothing was changed. Close \(n.count == 1 ? "it" : "them") yourself and try again."
        case .cancelled(let n):
            return "You chose to keep \(n) open, so nothing was changed."
        }
    }
}

// Closes Claude like a person would: ask it to quit, press "Quit anyway" if it asks (needs
// Accessibility access), and only as a last resort stop its child processes and force it closed.
enum QuitHelper {
    static let promptButtons: Set<String> = ["Quit anyway", "Quit Anyway", "Quit"]

    static var hasAccess: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestAccess() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }

    static func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    static func quit(_ targets: [QuitTarget], policy: QuitPolicy = .current, step: (String) -> Void) throws -> QuitReport {
        var report = QuitReport()
        let targets = targets.filter { !$0.pids.isEmpty }
        guard !targets.isEmpty else { return report }
        for t in targets { for pid in t.pids { kill(pid, SIGTERM) } }

        let start = Date()
        let limit: TimeInterval = policy == .quitAnyway ? 30 : 180
        var promptSeen = Set<String>()
        var told = Set<String>()

        while Date().timeIntervalSince(start) < limit {
            let open = targets.filter { $0.pids.contains(where: alive) }
            if open.isEmpty { break }
            let elapsed = Date().timeIntervalSince(start)
            for t in open {
                let asking = t.pids.contains { promptVisible(pid: $0) }
                if asking { promptSeen.insert(t.name) }
                switch policy {
                case .quitAnyway:
                    if asking, t.pids.contains(where: { pressQuitAnyway(pid: $0) }) {
                        if !report.answeredPrompt.contains(t.name) { report.answeredPrompt.append(t.name) }
                        step("\(t.name) asked before closing. Pressed Quit anyway.")
                    } else if !hasAccess && elapsed > 4 && !report.forced.contains(t.name) {
                        step("Closing \(t.name) by force")
                        t.pids.forEach(forceClose)
                        report.forced.append(t.name)
                    }
                case .askMe:
                    if asking && !told.contains(t.name) {
                        told.insert(t.name)
                        step("\(t.name) is asking whether to quit. Answer it in the Claude window.")
                    } else if promptSeen.contains(t.name) && !asking && hasAccess {
                        Thread.sleep(forTimeInterval: 1.0)
                        if t.pids.contains(where: alive) && !t.pids.contains(where: { promptVisible(pid: $0) }) {
                            throw QuitError.cancelled(t.name)
                        }
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.35)
        }

        var still = targets.filter { $0.pids.contains(where: alive) }
        if !still.isEmpty && policy == .quitAnyway {
            for t in still { step("Closing \(t.name) by force"); t.pids.forEach(forceClose); report.forced.append(t.name) }
            Thread.sleep(forTimeInterval: 1.0)
            still = targets.filter { $0.pids.contains(where: alive) }
        }
        if !still.isEmpty { throw QuitError.stillOpen(still.map(\.name)) }
        report.closed = targets.map(\.name)
        return report
    }

    // MARK: Accessibility

    static func promptButton(pid: Int32) -> AXUIElement? {
        guard hasAccess else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.6)
        for w in elements(app, kAXWindowsAttribute) {
            let sub = string(w, kAXSubroleAttribute) ?? ""
            if sub == "AXDialog" || sub == "AXSystemDialog" || sub == "AXUnknown" {
                if let b = findButton(in: w, depth: 0) { return b }
            }
            for child in elements(w, kAXChildrenAttribute) where string(child, kAXRoleAttribute) == "AXSheet" {
                if let b = findButton(in: child, depth: 0) { return b }
            }
        }
        return nil
    }

    static func promptVisible(pid: Int32) -> Bool { promptButton(pid: pid) != nil }

    static func pressQuitAnyway(pid: Int32) -> Bool {
        guard let b = promptButton(pid: pid) else { return false }
        return AXUIElementPerformAction(b, kAXPressAction as CFString) == .success
    }

    private static func findButton(in el: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 4 else { return nil }
        for c in elements(el, kAXChildrenAttribute) {
            let role = string(c, kAXRoleAttribute)
            if role == "AXButton", let t = string(c, kAXTitleAttribute), promptButtons.contains(t) { return c }
            if role == "AXWebArea" || role == "AXScrollArea" { continue }
            if let b = findButton(in: c, depth: depth + 1) { return b }
        }
        return nil
    }

    private static func elements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return [] }
        return (v as? [AXUIElement]) ?? []
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    // MARK: Force close

    static func forceClose(_ pid: Int32) {
        let tree = descendants(of: pid)
        for c in tree { kill(c, SIGTERM) }
        Thread.sleep(forTimeInterval: 0.8)
        for c in tree where alive(c) { kill(c, SIGKILL) }
        kill(pid, SIGKILL)
    }

    static func descendants(of root: Int32) -> [Int32] {
        let out = Scanner.shell("/bin/ps", ["-axo", "pid=,ppid="])
        var children: [Int32: [Int32]] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, let p = Int32(parts[0]), let pp = Int32(parts[1]) else { continue }
            children[pp, default: []].append(p)
        }
        var result: [Int32] = [], stack = children[root] ?? []
        while let p = stack.popLast() {
            result.append(p)
            stack += children[p] ?? []
        }
        return result
    }
}
