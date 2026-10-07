import SwiftUI
import ModAdmission

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            RootView(launch: LaunchOptions(arguments: ProcessInfo.processInfo.arguments))
        }
    }
}

/// `-tab registry|policy|env` and `-preset default|lead` let CI screenshot each screen.
struct LaunchOptions {
    var tab: Tab = .registry
    var lead = true

    init(arguments: [String]) {
        if let i = arguments.firstIndex(of: "-tab"), arguments.indices.contains(i + 1),
           let t = Tab(rawValue: arguments[i + 1]) {
            tab = t
        }
        if let i = arguments.firstIndex(of: "-preset"), arguments.indices.contains(i + 1) {
            lead = arguments[i + 1] != "default"
        }
    }
}

enum Tab: String, Hashable { case registry, policy, env }

@MainActor
final class GateModel: ObservableObject {
    @Published var allowManagedModsOnly = false
    @Published var blockSpawnAndEnvSet: Bool
    @Published var failClosed: Bool
    @Published var requirePins: Bool
    @Published var guardOnTeamPlan = true

    init(lead: Bool) {
        blockSpawnAndEnvSet = lead
        failClosed = lead
        requirePins = lead
    }

    var gate: AdmissionGate {
        var settings = SampleTeam.settings
        settings.allowManagedModsOnly = allowManagedModsOnly
        var plan = SampleTeam.plan
        if !guardOnTeamPlan {
            settings = .none
            plan = .personal
        }
        let policy = TeamPolicy(
            blockedCalls: blockSpawnAndEnvSet ? TeamPolicy.lead.blockedCalls : [],
            failClosed: failClosed,
            requirePins: requirePins,
            reviewAtOrAbove: requirePins ? .machine : nil
        )
        return AdmissionGate(settings: settings, plan: plan, policy: policy, pins: SampleTeam.pins)
    }

    var assessments: [Assessment] { gate.assess(SampleTeam.mods) }

    var exposures: [DenyExposure] {
        let g = gate
        return DenyCoverage.exposures(rule: SampleTeam.envRule, assessments: g.assess(SampleTeam.mods),
                                      settings: g.settings, plan: g.plan)
    }
}

struct RootView: View {
    @State private var tab: Tab
    @StateObject private var model: GateModel

    init(launch: LaunchOptions) {
        _tab = State(initialValue: launch.tab)
        _model = StateObject(wrappedValue: GateModel(lead: launch.lead))
    }

    var body: some View {
        TabView(selection: $tab) {
            RegistryView(model: model)
                .tabItem { Label("Registry", systemImage: "puzzlepiece.extension") }
                .tag(Tab.registry)
            PolicyView(model: model)
                .tabItem { Label("Policy", systemImage: "checklist") }
                .tag(Tab.policy)
            EnvView(model: model)
                .tabItem { Label("Read(.env)", systemImage: "key") }
                .tag(Tab.env)
        }
    }
}

struct VerdictBadge: View {
    let verdict: Verdict

    var color: Color {
        switch verdict {
        case .admit: return .green
        case .admitUnchecked: return .orange
        case .hold: return .yellow
        case .refuse: return .red
        }
    }

    var body: some View {
        Text(verdict.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color == .yellow ? Color.primary : color)
    }
}

struct RegistryView: View {
    @ObservedObject var model: GateModel

    var body: some View {
        NavigationStack {
            List(model.assessments) { a in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(a.id).font(.subheadline.monospaced()).lineLimit(1).minimumScaleFactor(0.7)
                        Spacer()
                        VerdictBadge(verdict: a.verdict)
                    }
                    Text("tier \(a.tier.rawValue) · radius \(a.radius.map { "\($0)" } ?? "unreadable")")
                        .font(.caption).foregroundStyle(.secondary)
                    if let first = a.verdict.reasons.first {
                        Text(first).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Mod registry")
        }
    }
}

struct PolicyView: View {
    @ObservedObject var model: GateModel

    var body: some View {
        let summary = GateSummary(model.assessments)
        NavigationStack {
            Form {
                Section("Result for 11 mods") {
                    LabeledContent("Load", value: "\(summary.loaded)")
                    LabeledContent("Load unchecked", value: "\(summary.admittedUnchecked)")
                    LabeledContent("Held for review", value: "\(summary.held)")
                    LabeledContent("Refused", value: "\(summary.refused)")
                    LabeledContent("Guard", value: model.gate.guardStatus.isLoaded ? "loaded" : "not loaded")
                }
                Section("Built-in guard") {
                    Toggle("Team plan with managed settings", isOn: $model.guardOnTeamPlan)
                    Toggle("allowManagedModsOnly", isOn: $model.allowManagedModsOnly)
                }
                Section("Team policy mod") {
                    Toggle("Block $.process.spawn, $.env.set", isOn: $model.blockSpawnAndEnvSet)
                    Toggle("Fail closed when the check fails", isOn: $model.failClosed)
                    Toggle("Require reviewed pins", isOn: $model.requirePins)
                }
            }
            .navigationTitle("Admission policy")
        }
    }
}

struct EnvView: View {
    @ObservedObject var model: GateModel

    var body: some View {
        let exposures = model.exposures
        let loaded = GateSummary(model.assessments).loaded
        NavigationStack {
            List {
                Section {
                    Text("\(exposures.count) of \(loaded) loaded mods can still reach .env")
                        .font(.headline)
                    Text("Deny rules cover Claude's tool calls, not a mod's own $.fs and $.process calls.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Paths around Read(.env)") {
                    ForEach(exposures) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.modID).font(.subheadline.monospaced())
                            ForEach(e.paths, id: \.self) { p in
                                Text("• " + p.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Deny-rule coverage")
        }
    }
}
