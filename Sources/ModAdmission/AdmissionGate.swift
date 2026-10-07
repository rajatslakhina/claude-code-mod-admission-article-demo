import Foundation

// The built-in guard protects what you manage. It does not decide which of
// your engineers' mods are fine to run. This gate is the policy a lead writes
// on top of it: refuse what the team never wants, hold what needs a human,
// and pin what was reviewed so a silent update can't ride in on an old yes.

/// One mod as the gate sees it.
public struct ModCandidate: Identifiable, Equatable, Sendable {
    /// `plugin@marketplace`
    public let id: String
    public let source: ModSource
    /// The raw `claude plugin validate` output for the plugin.
    public let validateOutput: String
    /// Concatenated source of the mod's modules; the pin digest is taken over it.
    public let code: String
    /// What happened when the team's policy check ran on it.
    public let check: CheckOutcome
    public let note: String

    public init(id: String, source: ModSource, validateOutput: String, code: String,
                check: CheckOutcome = .completed, note: String = "") {
        self.id = id
        self.source = source
        self.validateOutput = validateOutput
        self.code = code
        self.check = check
        self.note = note
    }

    public var digest: String { SHA256.hex(code) }
    public var surface: ModSurface? { try? ValidateOutput.parse(validateOutput) }
}

/// A `plugin.register` hook that throws or runs past its time limit is skipped,
/// so by default the check fails open and the mod loads anyway.
public enum CheckOutcome: String, Equatable, Sendable { case completed, threw, timedOut }

/// How far a mod reaches if it misbehaves.
public enum BlastRadius: Int, Comparable, Sendable, CustomStringConvertible {
    case contained = 0, session = 1, machine = 2

    public static func < (a: BlastRadius, b: BlastRadius) -> Bool { a.rawValue < b.rawValue }

    public var description: String {
        switch self {
        case .contained: return "contained"
        case .session: return "session"
        case .machine: return "machine"
        }
    }

    /// `machine`: writes files, runs programs or changes the environment every
    /// later command inherits. `session`: decides or rewrites what Claude does,
    /// reads secrets, reads files, or talks to the network. Otherwise contained.
    public static func of(_ s: ModSurface) -> BlastRadius {
        let r = s.reaches
        if r.contains(.writesFiles) || r.contains(.runsPrograms) || r.contains(.changesEnvironment) { return .machine }
        if s.strongestHook >= .rewrites || r.contains(.readsFiles) || r.contains(.network)
            || r.contains(.readsSecrets) || r.contains(.speaksAsUser) || r.contains(.spendsModel)
            || r.contains(.callsMCP) || r.contains(.unknown) || s.strongestHook == .unknown { return .session }
        return .contained
    }
}

/// The team's own rules, enforced by a policy mod in `prependPlugins`.
public struct TeamPolicy: Equatable, Sendable {
    public var blockedCalls: Set<ModCall>
    /// Refuse a user's mod whose check threw or timed out (the docs' `.catch` pattern).
    public var failClosed: Bool
    /// Hold any user mod whose code digest doesn't match an approved pin.
    public var requirePins: Bool
    /// Hold user mods at or above this radius until someone reviews them.
    public var reviewAtOrAbove: BlastRadius?

    public init(blockedCalls: Set<ModCall> = [], failClosed: Bool = false,
                requirePins: Bool = false, reviewAtOrAbove: BlastRadius? = nil) {
        self.blockedCalls = blockedCalls
        self.failClosed = failClosed
        self.requirePins = requirePins
        self.reviewAtOrAbove = reviewAtOrAbove
    }

    /// What you get when you change nothing.
    public static let none = TeamPolicy()

    /// The policy the article argues for.
    public static let lead = TeamPolicy(
        blockedCalls: [ModCall("process.spawn"), ModCall("env.set")],
        failClosed: true,
        requirePins: true,
        reviewAtOrAbove: .machine
    )
}

public enum Verdict: Equatable, Sendable {
    case admit
    /// Loaded without the team's check having run (fail-open).
    case admitUnchecked(String)
    case hold([String])
    case refuse([String])

    public var loads: Bool {
        switch self {
        case .admit, .admitUnchecked: return true
        case .hold, .refuse: return false
        }
    }

    public var label: String {
        switch self {
        case .admit: return "admit"
        case .admitUnchecked: return "admit (unchecked)"
        case .hold: return "hold"
        case .refuse: return "refuse"
        }
    }

    public var reasons: [String] {
        switch self {
        case .admit: return []
        case .admitUnchecked(let r): return [r]
        case .hold(let r), .refuse(let r): return r
        }
    }
}

public struct Assessment: Identifiable, Equatable, Sendable {
    public var id: String { candidate.id }
    public let candidate: ModCandidate
    public let tier: Tier
    public let surface: ModSurface?
    public let radius: BlastRadius?
    public let verdict: Verdict
}

public struct AdmissionGate: Sendable {
    public var settings: ManagedSettings
    public var plan: Plan
    public var policy: TeamPolicy
    /// `plugin@marketplace` -> approved SHA-256 of the mod's code
    public var pins: [String: String]

    public init(settings: ManagedSettings, plan: Plan, policy: TeamPolicy, pins: [String: String] = [:]) {
        self.settings = settings
        self.plan = plan
        self.policy = policy
        self.pins = pins
    }

    public var guardStatus: GuardStatus { TierResolver.guardStatus(settings: settings, plan: plan) }

    public func assess(_ c: ModCandidate) -> Assessment {
        let tier = TierResolver.tier(id: c.id, source: c.source, settings: settings)
        let surface = c.surface
        let radius = surface.map(BlastRadius.of)
        return Assessment(candidate: c, tier: tier, surface: surface, radius: radius,
                          verdict: verdict(c, tier: tier, surface: surface, radius: radius))
    }

    public func assess(_ all: [ModCandidate]) -> [Assessment] { all.map(assess) }

    private func verdict(_ c: ModCandidate, tier: Tier, surface: ModSurface?, radius: BlastRadius?) -> Verdict {
        // Organization and built-in mods aren't checked by the guard or by a policy mod.
        guard tier == .user else { return .admit }

        // Claude Code itself refuses what the validator can't read.
        guard let surface, let radius else {
            return .refuse(["validator could not read its use of the mods API"])
        }

        if guardStatus.isLoaded, settings.allowManagedModsOnly {
            return .refuse(["allowManagedModsOnly: only the organization's mods load"])
        }
        if settings.present, settings.disableSideloadFlags,
           c.source == .pluginDir || c.source == .sessionWritten {
            return .refuse(["disableSideloadFlags: sideloaded mods are rejected at startup"])
        }

        // The team's check didn't run. Docs default: skipped, so the mod loads.
        if c.check != .completed {
            let what = c.check == .threw ? "threw" : "timed out"
            if policy.failClosed { return .refuse(["policy check \(what); failing closed"]) }
            return .admitUnchecked("policy check \(what); skipped, mod loaded anyway")
        }

        let blocked = surface.calls.intersection(policy.blockedCalls).sorted()
        if !blocked.isEmpty {
            return .refuse(["calls blocked method " + blocked.map(\.description).joined(separator: ", ")])
        }

        var holds: [String] = []
        if policy.requirePins {
            if let pinned = pins[c.id] {
                if pinned != c.digest { holds.append("code changed since it was pinned") }
            } else {
                holds.append("no reviewed pin")
            }
        }
        if let floor = policy.reviewAtOrAbove, radius >= floor, pins[c.id] != c.digest {
            holds.append("\(radius) blast radius needs review")
        }
        return holds.isEmpty ? .admit : .hold(holds)
    }
}

/// Summary counts for a set of assessments.
public struct GateSummary: Equatable, Sendable {
    public let admitted: Int
    public let admittedUnchecked: Int
    public let held: Int
    public let refused: Int

    public init(_ a: [Assessment]) {
        admitted = a.filter { $0.verdict == .admit }.count
        admittedUnchecked = a.filter { if case .admitUnchecked = $0.verdict { return true }; return false }.count
        held = a.filter { if case .hold = $0.verdict { return true }; return false }.count
        refused = a.filter { if case .refuse = $0.verdict { return true }; return false }.count
    }

    public var loaded: Int { admitted + admittedUnchecked }
}
