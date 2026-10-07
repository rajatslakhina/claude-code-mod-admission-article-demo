import Foundation

// What a Claude Code mod can touch, as `claude plugin validate` reports it.
//
// The validator prints two lines per mod module, for example:
//
//   ❯ ./register.js hooks: session.start, tool.call, ui.render{component=Pane}
//   ❯ ./register.js calls: $.fs.read, $.http.fetch, $.store.set, $.ui.open
//
// and, when the mod touches environment variables, `env reads:` / `env writes:`
// lines that name each variable. This file models those lines as data.

/// One mods API method a mod's code calls, spelled `namespace.method`
/// (the `$.` prefix the validator prints is dropped, matching `e.uses.calls`).
public struct ModCall: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let name: String

    public init(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("$.") { s.removeFirst(2) }
        self.name = s
    }

    public var description: String { "$." + name }
    public static func < (a: ModCall, b: ModCall) -> Bool { a.name < b.name }

    /// What the call lets the mod reach, per the admin docs' review table.
    public var reach: Reach {
        switch name {
        case "fs.read": return .readsFiles
        case "fs.write": return .writesFiles
        case "process.run", "process.spawn": return .runsPrograms
        case "http.fetch": return .network
        case "env.get", "settings.read": return .readsSecrets
        case "env.set": return .changesEnvironment
        case "mcp.call": return .callsMCP
        case "model.complete": return .spendsModel
        case "prompt.submit", "session.send": return .speaksAsUser
        default:
            if name.hasPrefix("ui.") || name.hasPrefix("store.") { return .local }
            return .unknown
        }
    }
}

/// Coarse reach classes. `local` covers UI drawing and the mod's own store.
public enum Reach: String, CaseIterable, Sendable {
    case local, readsFiles, writesFiles, runsPrograms, network, readsSecrets
    case changesEnvironment, callsMCP, spendsModel, speaksAsUser, unknown

    /// Reach that no `deny` rule constrains: the docs say deny rules and managed
    /// `PreToolUse` hooks apply to Claude's tool calls, not to a mod's own
    /// `$.fs` and `$.process` calls.
    public var bypassesDenyRules: Bool {
        self == .readsFiles || self == .writesFiles || self == .runsPrograms
    }
}

/// One event a mod subscribes to, with its optional filter
/// (`ui.render{component=Pane}` has event `ui.render`, filter `component=Pane`).
public struct ModHook: Hashable, Sendable, CustomStringConvertible {
    public let event: String
    public let filter: String?

    public init(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let open = s.firstIndex(of: "{"), s.hasSuffix("}") {
            event = String(s[s.startIndex..<open])
            let inner = s[s.index(after: open)..<s.index(before: s.endIndex)]
            filter = inner.isEmpty ? nil : String(inner)
        } else {
            event = s
            filter = nil
        }
    }

    public var description: String { filter.map { "\(event){\($0)}" } ?? event }

    /// Hooks that let a mod change or decide what Claude does, rather than watch it.
    public var power: HookPower {
        switch event {
        case "tool.check": return .decides          // approve/deny before the prompt
        case "tool.call", "prompt.submit", "session.append": return .rewrites
        case "plugin.register": return .decides      // can refuse other mods
        case "ui.render":
            return filter == "component=AskUserQuestion" ? .rewrites : .observes
        case "session.start", "turn.start", "turn.complete", "command.run": return .observes
        default: return .unknown
        }
    }
}

public enum HookPower: Int, Comparable, Sendable {
    case observes = 0, unknown = 1, rewrites = 2, decides = 3
    public static func < (a: HookPower, b: HookPower) -> Bool { a.rawValue < b.rawValue }
}

/// The parsed validator output for one mod.
public struct ModSurface: Equatable, Sendable {
    public var hooks: [ModHook]
    public var calls: Set<ModCall>
    public var envReads: [String]
    public var envWrites: [String]

    public init(hooks: [ModHook], calls: Set<ModCall>, envReads: [String] = [], envWrites: [String] = []) {
        self.hooks = hooks
        self.calls = calls
        self.envReads = envReads
        self.envWrites = envWrites
    }

    public var reaches: Set<Reach> { Set(calls.map(\.reach)) }
    public var strongestHook: HookPower { hooks.map(\.power).max() ?? .observes }

    /// The mod can reach files or programs no matter what the deny rules say.
    public var bypassesDenyRules: Bool { reaches.contains { $0.bypassesDenyRules } }
}

public enum SurfaceError: Error, Equatable {
    /// No `hooks:` line. Claude Code refuses to load a mod whose use of the
    /// mods API the validator can't read, so the gate refuses it too.
    case unreadable
}

public enum ValidateOutput {
    /// Parses the `hooks:` / `calls:` / `env reads:` / `env writes:` lines.
    /// Lines from several modules of one plugin are merged.
    public static func parse(_ text: String) throws -> ModSurface {
        var hooks: [ModHook] = []
        var calls = Set<ModCall>()
        var envReads: [String] = []
        var envWrites: [String] = []
        var sawHooks = false

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if let list = value(after: "env reads:", in: line) {
                envReads += split(list)
            } else if let list = value(after: "env writes:", in: line) {
                envWrites += split(list)
            } else if let list = value(after: "hooks:", in: line) {
                sawHooks = true
                for item in split(list) where !hooks.contains(ModHook(item)) {
                    hooks.append(ModHook(item))
                }
            } else if let list = value(after: "calls:", in: line) {
                calls.formUnion(split(list).map(ModCall.init))
            }
        }
        guard sawHooks else { throw SurfaceError.unreadable }
        return ModSurface(hooks: hooks, calls: calls, envReads: envReads, envWrites: envWrites)
    }

    private static func value(after marker: String, in line: String) -> String? {
        guard let r = line.range(of: marker) else { return nil }
        return String(line[r.upperBound...])
    }

    /// Splits on commas that are not inside `{...}` filters.
    static func split(_ list: String) -> [String] {
        var out: [String] = []
        var current = ""
        var depth = 0
        for ch in list {
            switch ch {
            case "{": depth += 1; current.append(ch)
            case "}": depth = max(0, depth - 1); current.append(ch)
            case "," where depth == 0:
                let t = current.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append(t) }
                current = ""
            default: current.append(ch)
            }
        }
        let t = current.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty && t != "(none)" { out.append(t) }
        return out
    }
}
