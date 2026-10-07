import Foundation

// "I denied Read(.env), so nothing reads .env." Not for mods.
//
// Deny rules and managed PreToolUse hooks apply to Claude's tool calls. They
// do not apply to a mod's own `$.fs` and `$.process` calls, so a mod with
// `$.fs.read` can read the file and a mod with `$.process.run` can start a
// program that does. Separately, a mod with a `tool.check` hook can approve a
// call that a deny rule refuses when the guard isn't loaded, or when managed
// settings set `allowModsToOverrideDenyRules`.

public struct DenyRule: Hashable, Sendable, CustomStringConvertible {
    public let tool: String
    public let pattern: String

    public init(tool: String, pattern: String) {
        self.tool = tool
        self.pattern = pattern
    }

    /// Parses `Read(.env)`. Returns nil for anything else.
    public init?(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard let open = s.firstIndex(of: "("), s.hasSuffix(")"), open > s.startIndex else { return nil }
        let inner = s[s.index(after: open)..<s.index(before: s.endIndex)]
        guard !inner.isEmpty else { return nil }
        tool = String(s[s.startIndex..<open])
        pattern = String(inner)
    }

    public var description: String { "\(tool)(\(pattern))" }
}

public enum DenyPath: String, Sendable, CaseIterable {
    case readsDirectly = "reads it with $.fs.read"
    case viaProgram = "starts a program that can read it"
    case approvesDeniedCall = "can approve the denied tool call"
}

public struct DenyExposure: Identifiable, Equatable, Sendable {
    public var id: String { modID }
    public let modID: String
    public let paths: [DenyPath]
}

public enum DenyCoverage {
    /// Which loaded mods can still get at what `rule` protects.
    public static func exposures(rule: DenyRule, assessments: [Assessment],
                                 settings: ManagedSettings, plan: Plan) -> [DenyExposure] {
        let guardLoaded = TierResolver.guardStatus(settings: settings, plan: plan).isLoaded
        let denyHoldsAgainstMods = guardLoaded && !(settings.present && settings.allowModsToOverrideDenyRules)
        return assessments.compactMap { a in
            guard a.verdict.loads, let s = a.surface else { return nil }
            var paths: [DenyPath] = []
            if rule.tool == "Read" || rule.tool == "Edit" {
                if s.calls.contains(ModCall("fs.read")) {
                    paths.append(.readsDirectly)
                }
            }
            if s.calls.contains(ModCall("process.run")) || s.calls.contains(ModCall("process.spawn")) {
                paths.append(.viaProgram)
            }
            if !denyHoldsAgainstMods, s.hooks.contains(where: { $0.event == "tool.check" }) {
                paths.append(.approvesDeniedCall)
            }
            return paths.isEmpty ? nil : DenyExposure(modID: a.candidate.id, paths: paths)
        }
    }
}
