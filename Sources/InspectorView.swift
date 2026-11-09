import SwiftUI
import Charts

struct InspectorView: View {
    @EnvironmentObject var m: AppModel
    let p: Profile
    let snap: Snapshot
    var scrolls = true

    var body: some View {
        if scrolls { ScrollView { content }.scrollIndicators(.never) } else { content }
    }

    var content: some View {
            VStack(alignment: .leading, spacing: DS.xxl) {
                header
                limits
                if p.history.count > 1 { chart }
                chats
                details
            }
            .padding(DS.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(p.folder)
            .transition(.opacity)
            .animation(.smooth(duration: 0.25), value: p.folder)
    }

    var header: some View {
        VStack(alignment: .leading, spacing: DS.m) {
            HStack(alignment: .top, spacing: DS.m) {
                Avatar(p: p, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: DS.s) {
                        Text(p.displayName).font(.title2.weight(.semibold)).lineLimit(1)
                        if p.running {
                            StatusTag(text: snap.runningProfiles.count == 1 ? "In use" : "Open")
                        }
                    }
                    Text([p.fullName, p.plan].compactMap { $0 }.joined(separator: ", "))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: DS.s)
                HStack(spacing: DS.s) {
                    Button { m.renaming = ProfileRef(folder: p.folder) } label: { IconCircle(systemName: "pencil") }
                        .buttonStyle(.plain)
                        .help("Edit name, colour and app")
                    Menu {
                        ProfileActions(p: p, snap: snap)
                    } label: { IconCircle(systemName: "ellipsis") }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More actions")
                }
            }
            Text(p.email ?? "Not signed in yet. Open it once and sign in.")
                .textSelection(.enabled)
            let shared = snap.sharesAccount(p)
            if !shared.isEmpty {
                Text("\(p.displayName) and \(Fmt.list(shared.map(\.displayName))) use the same login, so they share one set of limits.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            mainButton
        }
    }

    @ViewBuilder var mainButton: some View {
        let onlyThisOpen = p.running && snap.runningProfiles.count == 1
        let behind = snap.behind(p)
        if p.targetDir == nil {
            Button { m.open(p) } label: { Text("Open \(p.displayName) to sign in").frame(maxWidth: .infinity) }
                .primaryAction().controlSize(.large)
        } else if onlyThisOpen {
            if behind > 0 {
                Button { m.requestSwitch(p.folder) } label: { Text("Bring in \(Fmt.plural(behind, "newer chat"))").frame(maxWidth: .infinity) }
                    .primaryAction().controlSize(.large)
            }
        } else {
            Button { m.requestSwitch(p.folder) } label: { Text("Switch to \(p.displayName)").frame(maxWidth: .infinity) }
                .primaryAction().controlSize(.large)
        }
    }

    var limits: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Limits").sectionTitle()
                Spacer()
                if !m.liveLimits {
                    Button("Get live limits") { m.turnOnLiveLimits() }.buttonStyle(.link).font(.callout)
                }
            }
            LimitBlock(title: "Next 5 hours", window: p.usage?.fiveHour)
            LimitBlock(title: "This week", window: p.usage?.week)
            if let f = p.usage?.fable { LimitBlock(title: "Fable this week", window: f) }
            if let u = p.usage {
                HStack(spacing: 6) {
                    Text("Updated \(Fmt.ago(u.takenAt)) by \(u.source).")
                    if m.liveLimits {
                        if m.checkingLimits { ProgressView().controlSize(.mini) }
                        else { Button("Check now") { m.refreshLimits(force: true) }.buttonStyle(.link) }
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let n = u.note {
                    Text(n).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    var chart: some View {
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        let pts = p.history.filter { $0.t > cutoff }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Used over the last week").sectionTitle()
            if pts.isEmpty {
                Text("Nothing used in the last 7 days.").font(.callout).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(Array(pts.enumerated()), id: \.offset) { _, s in
                        if let w = s.week {
                            AreaMark(x: .value("Time", s.t), y: .value("Used", w), series: .value("Limit", "Week"))
                                .foregroundStyle(Color.accentColor.opacity(0.12))
                                .interpolationMethod(.stepEnd)
                            LineMark(x: .value("Time", s.t), y: .value("Used", w), series: .value("Limit", "Week"))
                                .foregroundStyle(Color.accentColor)
                                .interpolationMethod(.stepEnd)
                        }
                        if let f = s.fiveHour {
                            LineMark(x: .value("Time", s.t), y: .value("Used", f), series: .value("Limit", "5-hour"))
                                .foregroundStyle(Color.orange.opacity(0.7))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .interpolationMethod(.stepEnd)
                        }
                    }
                }
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(values: [0, 50, 100]) { v in AxisGridLine(); AxisValueLabel("\(v.as(Int.self) ?? 0)%") } }
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
                .frame(height: 110)
                HStack(spacing: 14) {
                    legend(Color.accentColor, "Week used")
                    legend(.orange, "5-hour used")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func legend(_ c: Color, _ s: String) -> some View {
        HStack(spacing: 5) { Circle().fill(c).frame(width: 7, height: 7); Text(s) }
    }

    var chats: some View {
        let behind = snap.behind(p)
        let recent = p.ownChats.values.sorted { $0.lastActivity > $1.lastActivity }.prefix(5)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Chats").sectionTitle()
            Group {
                if p.targetDir == nil { Text("No chats until it's signed in.") }
                else if behind == 0 { Text("\(Fmt.plural(p.ownChats.count, "chat")). Nothing newer anywhere else.") }
                else { Text("\(Fmt.plural(p.ownChats.count, "chat")). \(behind) newer \(behind == 1 ? "one is" : "ones are") in other profiles.") }
            }
            .foregroundStyle(behind == 0 ? Color.secondary : Color.orange)
            ForEach(Array(recent)) { c in
                HStack(spacing: 8) {
                    Text(c.title).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Fmt.ago(c.lastActivity)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Details").sectionTitle()
            row("Folder", p.folder)
            if let app = p.shortcutApp { row("App", app.deletingPathExtension().lastPathComponent) }
            row("Backups", "\(m.backups[p.folder]?.count ?? 0)")
            if let a = p.accountUuid { row("Account ID", String(a.prefix(8)) + "…").help(a) }
        }
        .font(.callout)
    }

    func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).textSelection(.enabled).lineLimit(1)
        }
    }
}
