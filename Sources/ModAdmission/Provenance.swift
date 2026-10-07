import Foundation

// Where a mod came from decides which tier it runs in, and the tier decides
// which rules apply to it. The rules here follow the Claude Code admin docs
// ("Manage mods for your organization").

/// How the plugin that carries the mod was installed.
public enum ModSource: Equatable, Sendable {
    /// A marketplace that managed settings name as a directory on the machine,
    /// listing the plugin by a relative path so it loads in place.
    case managedDirectory(marketplacePath: String, relativePluginPath: Bool)
    /// A GitHub, git, URL or npm marketplace. Claude Code copies these into its
    /// cache, so they count as the user's even when managed settings enable them.
    case remote(String)
    /// `claude --plugin-dir ./some-mod`
    case pluginDir
    /// A mod Claude wrote during a session.
    case sessionWritten
    /// Built into Claude Code (AGENTS.md support, the sec-default guard).
    case builtin
}

/// The tier a mod runs in, spelled the way `e.tier` spells it.
public enum Tier: String, Sendable, CaseIterable {
    case prepend, builtin, user, append
}

public enum Plan: String, Sendable { case personal, team, enterprise, apiKey }

/// The managed-settings keys that matter for mods. `present == false` models
/// a machine with no managed settings at all.
public struct ManagedSettings: Equatable, Sendable {
    public var present: Bool
    public var enabledPlugins: Set<String>
    /// marketplace name -> absolute directory path
    public var directoryMarketplaces: [String: String]
    /// nil = key not set (default order); an empty or explicit list replaces the default.
    public var prependPlugins: [String]?
    public var appendPlugins: [String]?
    public var allowManagedModsOnly: Bool
    public var allowModsToOverrideDenyRules: Bool
    public var disableSideloadFlags: Bool

    public static let guardID = "sec-default@builtin"

    public init(present: Bool = true,
                enabledPlugins: Set<String> = [],
                directoryMarketplaces: [String: String] = [:],
                prependPlugins: [String]? = nil,
                appendPlugins: [String]? = nil,
                allowManagedModsOnly: Bool = false,
                allowModsToOverrideDenyRules: Bool = false,
                disableSideloadFlags: Bool = false) {
        self.present = present
        self.enabledPlugins = enabledPlugins
        self.directoryMarketplaces = directoryMarketplaces
        self.prependPlugins = prependPlugins
        self.appendPlugins = appendPlugins
        self.allowManagedModsOnly = allowManagedModsOnly
        self.allowModsToOverrideDenyRules = allowModsToOverrideDenyRules
        self.disableSideloadFlags = disableSideloadFlags
    }

    public static let none = ManagedSettings(present: false)
}

public enum GuardStatus: Equatable, Sendable {
    case loaded
    case notLoaded(reason: String)

    public var isLoaded: Bool { self == .loaded }
}

public enum TierResolver {
    /// The built-in guard loads when the machine has managed settings or the
    /// user is on a Team/Enterprise plan. Setting `prependPlugins` in managed
    /// settings replaces the default order, so a list that leaves the guard
    /// out removes it.
    public static func guardStatus(settings: ManagedSettings, plan: Plan) -> GuardStatus {
        let eligible = settings.present || plan == .team || plan == .enterprise
        guard eligible else {
            return .notLoaded(reason: "no managed settings and a \(plan.rawValue) plan")
        }
        if settings.present, let list = settings.prependPlugins, !list.contains(ManagedSettings.guardID) {
            return .notLoaded(reason: "prependPlugins is set and does not name \(ManagedSettings.guardID)")
        }
        return .loaded
    }

    /// A mod counts as the organization's only when managed `enabledPlugins`
    /// turns it on, its marketplace is a managed directory given by absolute
    /// path, and the marketplace lists it by relative path.
    public static func isOrganizationMod(id: String, source: ModSource, settings: ManagedSettings) -> Bool {
        guard settings.present, settings.enabledPlugins.contains(id) else { return false }
        guard case let .managedDirectory(path, relative) = source, relative, path.hasPrefix("/") else {
            return false
        }
        guard let marketplace = id.split(separator: "@").last.map(String.init),
              settings.directoryMarketplaces[marketplace] == path else { return false }
        return true
    }

    public static func tier(id: String, source: ModSource, settings: ManagedSettings) -> Tier {
        if source == .builtin { return .builtin }
        guard isOrganizationMod(id: id, source: source, settings: settings) else { return .user }
        if settings.appendPlugins?.contains(id) == true { return .append }
        // An organization's mod runs ahead of users' mods even when no list names it.
        return .prepend
    }
}
