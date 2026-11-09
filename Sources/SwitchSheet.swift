import SwiftUI

struct SwitchSheet: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.dismiss) var dismiss
    let request: SwitchRequest

    enum Phase: Equatable { case review, running, done, failed }
    enum StepState: Equatable { case waiting, active, done, skipped, failed }

    @State private var mode: SourceMode = .newestEverywhere
    @State private var openAfter = true
    @State private var plan: SyncPlan?
    @State private var planError: String?
    @State private var phase: Phase = .review
    @State private var current: SwitchStep?
    @State private var liveText: [SwitchStep: String] = [:]
    @State private var result: SyncResult?
    @State private var failure: String?
    @State private var showChats = false

    var target: Profile? { m.snap?.profile(request.target) }
    var name: String { target?.displayName ?? request.target }
    var onlyTargetOpen: Bool { m.snap?.runningProfiles.map(\.folder) == [request.target] }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if let e = planError {
                Text(e).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else {
                if phase == .review { sourcePicker }
                steps
                if phase == .review, let plan { warnings(plan) }
                if phase == .failed, let failure {
                    Text(failure).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            footer
        }
        .padding(DS.xxl)
        .frame(width: DS.sheetWidth)
        .animation(.smooth(duration: 0.3), value: phase)
        .animation(.smooth(duration: 0.3), value: current)
        .onAppear {
            mode = request.mode
            openAfter = m.openAfterSwitch
            rebuild()
        }
        .onChange(of: mode) { _, _ in rebuild() }
        .interactiveDismissDisabled(phase == .running)
    }

    func rebuild() {
        guard let snap = m.snap else { return }
        do { plan = try SyncEngine.plan(snap, target: request.target, mode: mode); planError = nil }
        catch { plan = nil; planError = error.localizedDescription }
    }

    // MARK: Header

    @ViewBuilder var header: some View {
        HStack(spacing: 14) {
            ZStack {
                if let t = target { Avatar(p: t, size: 44) }
                if phase == .done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white, .green)
                        .offset(x: 16, y: 16)
                        .transition(.scale.combined(with: .opacity))
                        .symbolEffect(.bounce, value: phase == .done)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.semibold))
                    .contentTransition(.opacity)
                Text(subtitle).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            SwitchMochi(phase: phase)
        }
    }

    var title: String {
        switch phase {
        case .done: return (result?.opened ?? true) ? "You're on \(name)" : "\(name) is up to date"
        case .failed: return "Couldn't switch"
        case .running: return onlyTargetOpen ? "Updating \(name)…" : "Switching to \(name)…"
        case .review: return onlyTargetOpen ? "Update \(name)" : "Switch to \(name)"
        }
    }

    var subtitle: String {
        [target?.email, target?.plan].compactMap { $0 }.joined(separator: ", ")
    }

    var sourcePicker: some View {
        Picker("Take chats from", selection: $mode) {
            Text("Wherever they're newest").tag(SourceMode.newestEverywhere)
            Divider()
            ForEach((m.snap?.profiles ?? []).filter { $0.folder != request.target }) { p in
                Text("\(p.displayName) only").tag(SourceMode.profile(p.folder))
            }
        }
        .disabled(phase != .review)
    }

    // MARK: Steps

    @ViewBuilder var steps: some View {
        if let plan {
            VStack(alignment: .leading, spacing: 14) {
                stepRow(.close, title: closeTitle(plan), detail: liveText[.close] ?? closeDetail(plan))
                stepRow(.backup, title: "Back up \(name)'s chats", detail: liveText[.backup] ?? "So you can undo this from Backups.")
                VStack(alignment: .leading, spacing: 6) {
                    stepRow(.copy, title: copyTitle(plan), detail: liveText[.copy] ?? copyDetail(plan))
                    if !plan.copies.isEmpty && phase == .review {
                        DisclosureGroup(isExpanded: $showChats) {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(plan.copies.prefix(40)) { c in
                                    HStack(spacing: 8) {
                                        Text(c.kind == .added ? "New" : "Newer")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(c.kind == .added ? Color.accentColor : Color.secondary)
                                            .frame(width: 38, alignment: .leading)
                                        Text(c.title).lineLimit(1)
                                        Spacer(minLength: 6)
                                        Text("from \(m.snap?.profile(c.from)?.displayName ?? c.from)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            Text(showChats ? "Hide the list" : "Show which chats").font(.callout)
                        }
                        .padding(.leading, 34)
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    icon(.open)
                    VStack(alignment: .leading, spacing: 2) {
                        if phase == .review {
                            Toggle("Open \(name) afterwards", isOn: $openAfter)
                                .toggleStyle(.checkbox)
                        } else {
                            Text(openAfter ? "Open \(name)" : "Leave \(name) closed")
                        }
                        if let t = liveText[.open] { Text(t).font(.callout).foregroundStyle(.secondary) }
                    }
                }
            }
            .card()
        }
    }

    func stepRow(_ s: SwitchStep, title: String, detail: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            icon(s)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
            }
        }
    }

    func state(_ s: SwitchStep) -> StepState {
        switch phase {
        case .review: return .waiting
        case .done:
            if s == .close && (result?.quit.closed.isEmpty ?? true) { return .skipped }
            if s == .open && !openAfter { return .skipped }
            return .done
        case .running, .failed:
            guard let c = current else { return phase == .failed ? .failed : .waiting }
            if s < c { return (s == .close && liveText[.close] == nil) ? .skipped : .done }
            if s == c { return phase == .failed ? .failed : .active }
            return .waiting
        }
    }

    @ViewBuilder func icon(_ s: SwitchStep) -> some View {
        let st = state(s)
        ZStack {
            switch st {
            case .waiting:
                Image(systemName: "\(s.rawValue + 1).circle").foregroundStyle(.secondary)
            case .active:
                ProgressView().controlSize(.small)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            case .skipped:
                Image(systemName: "minus.circle").foregroundStyle(.tertiary)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
        .font(.system(size: 17))
        .frame(width: 22, height: 20)
        .animation(.spring(duration: 0.35, bounce: 0.4), value: st)
    }

    func closeTitle(_ p: SyncPlan) -> String {
        let names = p.toQuit.map(\.displayName)
        if names.isEmpty { return "Nothing to close" }
        if names == [p.targetName] { return "Close \(p.targetName) for a moment" }
        return "Close \(Fmt.list(names))"
    }

    func closeDetail(_ p: SyncPlan) -> String {
        if p.toQuit.isEmpty { return "No Claude window is open." }
        if let busy = p.recentlyActive.first {
            return "“\(busy.title)” was busy \(Fmt.ago(busy.lastActivity)). Anything still running there stops."
        }
        if m.quitPolicy == .quitAnyway {
            return m.hasAccess ? "If Claude asks “Quit anyway?”, Relaycat answers yes." : "If Claude asks “Quit anyway?”, Relaycat closes it by force."
        }
        return "If Claude asks “Quit anyway?”, you answer it in Claude."
    }

    func copyTitle(_ p: SyncPlan) -> String {
        if p.copies.isEmpty { return p.relinks > 0 ? "Fix \(Fmt.plural(p.relinks, "chat")) that depend on other profiles" : "Chats are already up to date" }
        var parts: [String] = []
        if p.added > 0 { parts.append("\(p.added) new") }
        if p.updated > 0 { parts.append("\(p.updated) updated") }
        return "Copy \(Fmt.list(parts)) \(p.copies.count == 1 ? "chat" : "chats")"
    }

    func copyDetail(_ p: SyncPlan) -> String {
        var s = "\(name) will have \(Fmt.plural(p.totalAfter, "chat"))"
        if !p.notes.isEmpty { s += ", plus \(Fmt.plural(p.notes.count, "note")) that go with them" }
        s += "."
        if p.relinks > 0 {
            s += " \(Fmt.plural(p.relinks, "chat")) here still \(p.relinks == 1 ? "uses" : "use") files kept in another profile. Those files get copied in, so \(p.relinks == 1 ? "it keeps" : "they keep") working if that profile is deleted."
        }
        return s
    }

    @ViewBuilder func warnings(_ p: SyncPlan) -> some View {
        if !p.keptNewer.isEmpty {
            Text("\(Fmt.plural(p.keptNewer.count, "chat")) in \(name) \(p.keptNewer.count == 1 ? "is" : "are") newer than that copy, so \(p.keptNewer.count == 1 ? "it stays" : "they stay") as \(p.keptNewer.count == 1 ? "it is" : "they are").")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if !m.hasAccess && m.quitPolicy == .quitAnyway && !p.toQuit.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("Allow Accessibility access to close Claude cleanly instead of by force.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Allow…") { m.askForAccess() }.controlSize(.small)
            }
        }
    }

    // MARK: Footer

    @ViewBuilder var footer: some View {
        HStack {
            if phase == .done, let b = result?.backup {
                Button("Show backup") { NSWorkspace.shared.activateFileViewerSelecting([b]) }.buttonStyle(.link)
            }
            Spacer()
            switch phase {
            case .review:
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(primaryLabel) { start() }
                    .keyboardShortcut(.defaultAction)
                    .primaryAction()
                    .disabled(plan == nil)
            case .running:
                Text("Keep this open until it finishes.").font(.callout).foregroundStyle(.secondary)
            case .done, .failed:
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).primaryAction()
            }
        }
    }

    var primaryLabel: String {
        guard let plan else { return "Switch" }
        if onlyTargetOpen { return plan.copies.isEmpty && plan.notes.isEmpty && plan.relinks == 0 ? "Reopen" : "Update" }
        return "Switch"
    }

    // MARK: Run

    func simulate() {
        withAnimation { phase = .running; current = .close }
        let steps: [(SwitchStep, String, Double)] = [(.close, "Closing the open Claude", 0.2), (.backup, "Backing up chats", 1.4),
                                                     (.copy, "Copying chats", 2.4), (.open, "Opening \(name)", 3.4)]
        for (s, text, delay) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { withAnimation(.smooth) { current = s; liveText[s] = text } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.4) {
            liveText[.close] = "Closed the open Claude."; liveText[.backup] = "Saved a backup."
            liveText[.copy] = "Copied the newer chats."; liveText[.open] = "\(name) is open."
            withAnimation(.spring(duration: 0.45, bounce: 0.3)) { phase = .done }
            Haptic.done()
        }
    }

    func start() {
        if m.isDemo { simulate(); return }
        let scanner = m.scanner, target = request.target, mode = self.mode
        let opts = SyncOptions(quitOthers: true, openAfter: openAfter)
        m.openAfterSwitch = openAfter
        let sourceName: String = {
            if case .profile(let f) = mode { return m.snap?.profile(f)?.displayName ?? f }
            return "wherever newest"
        }()
        m.working = true
        Haptic.tick()
        withAnimation { phase = .running; current = .close }
        Task.detached {
            do {
                let r = try SyncEngine.run(scanner: scanner, target: target, mode: mode, options: opts) { step, text in
                    Task { @MainActor in
                        withAnimation(.smooth) { current = step; liveText[step] = text }
                    }
                }
                await MainActor.run {
                    var closeText: String? = nil
                    if !r.quit.answeredPrompt.isEmpty { closeText = "Answered “Quit anyway” for \(Fmt.list(r.quit.answeredPrompt))." }
                    else if !r.quit.forced.isEmpty { closeText = "Closed \(Fmt.list(r.quit.forced)) by force." }
                    else if !r.quit.closed.isEmpty { closeText = "Closed \(Fmt.list(r.quit.closed))." }
                    if let closeText { liveText[.close] = closeText }
                    liveText[.backup] = r.backup.map { "Saved as \($0.lastPathComponent)." }
                    liveText[.copy] = r.plan.copies.isEmpty ? "Nothing needed copying." : "Copied \(Fmt.plural(r.plan.copies.count, "chat")). \(r.plan.targetName) has \(r.plan.totalAfter) now."
                    if r.opened { liveText[.open] = r.openedRunning ? "\(r.plan.targetName) is open." : "Starting up. Give it a few seconds." }
                    result = r
                    withAnimation(.spring(duration: 0.45, bounce: 0.3)) { phase = .done }
                    Haptic.done()
                    m.working = false
                    m.addHistory(HistoryEntry(date: Date(), kind: "switch", target: r.plan.targetName, source: sourceName,
                                              added: r.plan.added, updated: r.plan.updated, notes: r.plan.notes.count,
                                              quit: r.quit.closed, backup: r.backup?.path, ok: true,
                                              message: r.quit.forced.isEmpty ? "" : "Closed \(Fmt.list(r.quit.forced)) by force"))
                    m.refresh()
                }
            } catch {
                await MainActor.run {
                    failure = error.localizedDescription
                    withAnimation { phase = .failed }
                    m.working = false
                    m.addHistory(HistoryEntry(date: Date(), kind: "switch", target: m.snap?.profile(target)?.displayName ?? target,
                                              source: sourceName, added: 0, updated: 0, notes: 0, quit: [], backup: nil,
                                              ok: false, message: error.localizedDescription))
                    m.refresh()
                }
            }
        }
    }
}

/// Mochi in the switch sheet: ears perk up while it works, a happy hop when it's done.
struct SwitchMochi: View {
    let phase: SwitchSheet.Phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hop = false

    var body: some View {
        Group {
            switch phase {
            case .running where !reduceMotion:
                TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    MochiFace(mood: .ready, size: 52, earTilt: sin(t * 9) * 9)
                }
            case .done:
                MochiFace(mood: .happy, size: 52)
                    .offset(y: hop ? -10 : 0)
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.spring(duration: 0.28, bounce: 0.5)) { hop = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                            withAnimation(.spring(duration: 0.4, bounce: 0.55)) { hop = false }
                        }
                    }
            case .failed:
                MochiFace(mood: .tired, size: 52)
            default:
                LiveMochi(mood: .ready, size: 52)
            }
        }
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}
