import Foundation

// A constructed registry for one iOS team: eleven mods of the kinds teams are
// writing in the first week of Claude Code mods. The validator lines follow the
// format `claude plugin validate` prints; the code bodies are stand-ins whose
// only job is to give each mod a stable digest. None of this is a survey of
// real plugins.

public enum SampleTeam {
    public static let marketplacePath = "/opt/acme/claude-plugins"

    /// Team plan, managed settings deployed, default mod order, guard options unset.
    public static let settings = ManagedSettings(
        present: true,
        enabledPlugins: ["secrets-redactor@acme-tools", "pr-template@acme-github"],
        directoryMarketplaces: ["acme-tools": marketplacePath]
    )

    public static let plan: Plan = .team

    private static func v(_ hooks: String, _ calls: String, env: String? = nil, envWrites: String? = nil) -> String {
        var lines = ["  ❯ ./register.js hooks: \(hooks)", "  ❯ ./register.js calls: \(calls)"]
        if let env { lines.append("  ❯ ./register.js env reads: \(env)") }
        if let envWrites { lines.append("  ❯ ./register.js env writes: \(envWrites)") }
        return lines.joined(separator: "\n")
    }

    public static let mods: [ModCandidate] = [
        ModCandidate(id: "secrets-redactor@acme-tools",
                     source: .managedDirectory(marketplacePath: marketplacePath, relativePluginPath: true),
                     validateOutput: v("session.append, tool.call", "$.fs.read, $.ui.log"),
                     code: "export function register(on){ on('session.append', redact) } // v3",
                     note: "Platform team's redactor, installed in place by MDM"),
        ModCandidate(id: "pr-template@acme-github",
                     source: .remote("github"),
                     validateOutput: v("session.start", "$.fs.read, $.fs.write"),
                     code: "export function register(on){ on('session.start', writeTemplate) } // v1",
                     note: "Enabled in managed settings, but installed from GitHub"),
        ModCandidate(id: "xcode-build-digest@ios-guild",
                     source: .remote("github"),
                     validateOutput: v("tool.call", "$.process.run, $.fs.read, $.ui.log"),
                     code: "export function register(on){ on('tool.call', digestXcodebuild) } // v2",
                     note: "Collapses xcodebuild output to the first error"),
        ModCandidate(id: "sim-state@ios-guild",
                     source: .remote("github"),
                     validateOutput: v("session.start, prompt.submit", "$.process.run, $.store.set"),
                     code: "export function register(on){ on('prompt.submit', addSimctlState) } // v5",
                     note: "Adds booted-simulator state to each prompt"),
        ModCandidate(id: "snapshot-diff@ios-guild",
                     source: .remote("github"),
                     validateOutput: v("tool.call, ui.render{component=Pane}", "$.fs.read, $.ui.open"),
                     code: "export function register(on){ on('ui.render', diffPane) } // v1",
                     check: .timedOut,
                     note: "Snapshot-test diff pane; the policy check timed out on it"),
        ModCandidate(id: "statusline-tokens@community",
                     source: .remote("github"),
                     validateOutput: v("ui.render{component=StatusLine}", "$.store.get, $.store.set"),
                     code: "export function register(on){ on('ui.render', tokens) } // v4",
                     note: "Token counter in the status line"),
        ModCandidate(id: "jira-context@community",
                     source: .remote("npm"),
                     validateOutput: v("prompt.submit", "$.http.fetch, $.env.get", env: "JIRA_TOKEN"),
                     code: "export function register(on){ on('prompt.submit', attachTicket) } // v2",
                     note: "Pulls the linked ticket into the prompt"),
        ModCandidate(id: "swiftformat-autoapprove@community",
                     source: .remote("github"),
                     validateOutput: v("tool.check", "$.ui.log"),
                     code: "export function register(on){ on('tool.check', approveSwiftFormat) } // v1",
                     note: "Approves `swiftformat` without a prompt"),
        ModCandidate(id: "slack-done@community",
                     source: .remote("github"),
                     validateOutput: v("turn.complete", "$.http.fetch, $.settings.read"),
                     code: "export function register(on){ on('turn.complete', postToSlack) } // v3",
                     note: "Posts to Slack when a long turn finishes"),
        ModCandidate(id: "bundle-helper@community",
                     source: .remote("url"),
                     validateOutput: "  ✘ ./register.js: could not determine mods API usage (dynamic import)",
                     code: "export async function register(on){ (await import(u)).default(on) }",
                     note: "Loads its real code at runtime"),
        ModCandidate(id: "scratch-mod",
                     source: .sessionWritten,
                     validateOutput: v("tool.call", "$.fs.write, $.process.spawn, $.env.set", envWrites: "PATH"),
                     code: "export function register(on){ on('tool.call', wrapBuild) } // written by Claude",
                     note: "Written by Claude during a session"),
    ]

    /// Pins a lead approved after review. sim-state was reviewed at v4; it is now v5.
    public static let pins: [String: String] = [
        "xcode-build-digest@ios-guild": SHA256.hex("export function register(on){ on('tool.call', digestXcodebuild) } // v2"),
        "statusline-tokens@community": SHA256.hex("export function register(on){ on('ui.render', tokens) } // v4"),
        "jira-context@community": SHA256.hex("export function register(on){ on('prompt.submit', attachTicket) } // v2"),
        "sim-state@ios-guild": SHA256.hex("export function register(on){ on('prompt.submit', addSimctlState) } // v4"),
    ]

    public static var defaultGate: AdmissionGate {
        AdmissionGate(settings: settings, plan: plan, policy: .none)
    }

    public static var leadGate: AdmissionGate {
        AdmissionGate(settings: settings, plan: plan, policy: .lead, pins: pins)
    }

    public static let envRule = DenyRule(tool: "Read", pattern: ".env")
}
