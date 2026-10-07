import XCTest
@testable import ModAdmission

final class SurfaceTests: XCTestCase {
    func testParsesValidatorLinesAndDropsDollarPrefix() throws {
        let text = """
          ❯ ./register.js hooks: session.start, tool.call, ui.render{component=Pane}
          ❯ ./register.js calls: $.fs.read, $.http.fetch, $.store.set, $.ui.open
        """
        let s = try ValidateOutput.parse(text)
        XCTAssertEqual(s.hooks.map(\.description), ["session.start", "tool.call", "ui.render{component=Pane}"])
        XCTAssertEqual(s.calls, [ModCall("fs.read"), ModCall("http.fetch"), ModCall("store.set"), ModCall("ui.open")])
        XCTAssertTrue(s.calls.contains(ModCall("$.fs.read")))
    }

    func testCommaInsideFilterDoesNotSplit() {
        XCTAssertEqual(ValidateOutput.split("ui.render{component=Pane,slot=top}, tool.call"),
                       ["ui.render{component=Pane,slot=top}", "tool.call"])
    }

    func testEnvLinesAreNotMistakenForCalls() throws {
        let s = try ValidateOutput.parse("""
          ❯ ./a.js hooks: prompt.submit
          ❯ ./a.js calls: $.env.get
          ❯ ./a.js env reads: JIRA_TOKEN, HOME
        """)
        XCTAssertEqual(s.envReads, ["JIRA_TOKEN", "HOME"])
        XCTAssertEqual(s.calls, [ModCall("env.get")])
    }

    func testMissingHooksLineIsUnreadable() {
        XCTAssertThrowsError(try ValidateOutput.parse("  ✘ ./register.js: dynamic import")) { error in
            XCTAssertEqual(error as? SurfaceError, .unreadable)
        }
        XCTAssertThrowsError(try ValidateOutput.parse(""))
    }

    func testHookPowerOrdering() {
        XCTAssertEqual(ModHook("tool.check").power, .decides)
        XCTAssertEqual(ModHook("tool.call").power, .rewrites)
        XCTAssertEqual(ModHook("ui.render{component=AskUserQuestion}").power, .rewrites)
        XCTAssertEqual(ModHook("ui.render{component=Pane}").power, .observes)
        XCTAssertEqual(ModHook("something.new").power, .unknown)
    }

    func testBlastRadius() throws {
        let contained = try ValidateOutput.parse("hooks: ui.render{component=StatusLine}\ncalls: $.store.get")
        let session = try ValidateOutput.parse("hooks: tool.check\ncalls: $.ui.log")
        let machine = try ValidateOutput.parse("hooks: turn.complete\ncalls: $.process.run")
        XCTAssertEqual(BlastRadius.of(contained), .contained)
        XCTAssertEqual(BlastRadius.of(session), .session)
        XCTAssertEqual(BlastRadius.of(machine), .machine)
    }
}

final class ProvenanceTests: XCTestCase {
    let org = ModSource.managedDirectory(marketplacePath: SampleTeam.marketplacePath, relativePluginPath: true)

    func testGuardLoadsOnTeamPlanOrWithManagedSettings() {
        XCTAssertTrue(TierResolver.guardStatus(settings: .none, plan: .team).isLoaded)
        XCTAssertTrue(TierResolver.guardStatus(settings: .none, plan: .enterprise).isLoaded)
        XCTAssertTrue(TierResolver.guardStatus(settings: ManagedSettings(), plan: .personal).isLoaded)
        XCTAssertFalse(TierResolver.guardStatus(settings: .none, plan: .personal).isLoaded)
        XCTAssertFalse(TierResolver.guardStatus(settings: .none, plan: .apiKey).isLoaded)
    }

    func testPrependListThatOmitsTheGuardRemovesIt() {
        var s = SampleTeam.settings
        s.prependPlugins = ["secrets-redactor@acme-tools"]
        XCTAssertFalse(TierResolver.guardStatus(settings: s, plan: .team).isLoaded)
        s.prependPlugins = ["secrets-redactor@acme-tools", "sec-default@builtin"]
        XCTAssertTrue(TierResolver.guardStatus(settings: s, plan: .team).isLoaded)
    }

    func testManagedEnableAloneDoesNotMakeARemotePluginTheOrganizations() {
        let s = SampleTeam.settings
        XCTAssertEqual(TierResolver.tier(id: "pr-template@acme-github", source: .remote("github"), settings: s), .user)
        XCTAssertEqual(TierResolver.tier(id: "secrets-redactor@acme-tools", source: org, settings: s), .prepend)
    }

    func testOrganizationModNeedsAllThreeConditions() {
        let s = SampleTeam.settings
        // Not enabled in managed settings.
        XCTAssertFalse(TierResolver.isOrganizationMod(id: "other@acme-tools", source: org, settings: s))
        // Plugin listed by an absolute path (copied, not loaded in place).
        let copied = ModSource.managedDirectory(marketplacePath: SampleTeam.marketplacePath, relativePluginPath: false)
        XCTAssertFalse(TierResolver.isOrganizationMod(id: "secrets-redactor@acme-tools", source: copied, settings: s))
        // Marketplace path is relative.
        let relative = ModSource.managedDirectory(marketplacePath: "opt/acme", relativePluginPath: true)
        XCTAssertFalse(TierResolver.isOrganizationMod(id: "secrets-redactor@acme-tools", source: relative, settings: s))
        // No managed settings at all.
        XCTAssertFalse(TierResolver.isOrganizationMod(id: "secrets-redactor@acme-tools", source: org, settings: .none))
    }

    func testAppendListedOrgModRunsLast() {
        var s = SampleTeam.settings
        s.appendPlugins = ["secrets-redactor@acme-tools"]
        XCTAssertEqual(TierResolver.tier(id: "secrets-redactor@acme-tools", source: org, settings: s), .append)
        XCTAssertEqual(TierResolver.tier(id: "x@builtin", source: .builtin, settings: s), .builtin)
    }
}

final class GateTests: XCTestCase {
    func testDefaultsLoadTenOfElevenAndFailOpen() {
        let a = SampleTeam.defaultGate.assess(SampleTeam.mods)
        XCTAssertEqual(a.count, 11)
        let summary = GateSummary(a)
        XCTAssertEqual(summary.loaded, 10)
        XCTAssertEqual(summary.admittedUnchecked, 1)
        XCTAssertEqual(summary.refused, 1)
        let snapshot = a.first { $0.id == "snapshot-diff@ios-guild" }
        XCTAssertEqual(snapshot?.verdict, .admitUnchecked("policy check timed out; skipped, mod loaded anyway"))
    }

    func testLeadPolicyLoadsFourHoldsFourRefusesThree() {
        let a = SampleTeam.leadGate.assess(SampleTeam.mods)
        let summary = GateSummary(a)
        XCTAssertEqual(summary.admitted, 4)
        XCTAssertEqual(summary.admittedUnchecked, 0)
        XCTAssertEqual(summary.held, 4)
        XCTAssertEqual(summary.refused, 3)
        XCTAssertEqual(Set(a.filter { $0.verdict.loads }.map(\.id)),
                       ["secrets-redactor@acme-tools", "xcode-build-digest@ios-guild",
                        "statusline-tokens@community", "jira-context@community"])
    }

    func testPinDriftHoldsAnUpdatedMod() throws {
        let a = SampleTeam.leadGate.assess(SampleTeam.mods)
        let sim = try XCTUnwrap(a.first { $0.id == "sim-state@ios-guild" })
        XCTAssertEqual(sim.verdict, .hold(["code changed since it was pinned", "machine blast radius needs review"]))
    }

    func testReviewedPinSatisfiesMachineRadiusReview() throws {
        let a = SampleTeam.leadGate.assess(SampleTeam.mods)
        let digest = try XCTUnwrap(a.first { $0.id == "xcode-build-digest@ios-guild" })
        XCTAssertEqual(digest.radius, .machine)
        XCTAssertEqual(digest.verdict, .admit)
    }

    func testBlockedCallsAreListedSorted() throws {
        let a = SampleTeam.leadGate.assess(SampleTeam.mods)
        let scratch = try XCTUnwrap(a.first { $0.id == "scratch-mod" })
        XCTAssertEqual(scratch.verdict, .refuse(["calls blocked method $.env.set, $.process.spawn"]))
    }

    func testAllowManagedModsOnlyRefusesEveryUserMod() {
        var gate = SampleTeam.defaultGate
        gate.settings.allowManagedModsOnly = true
        let a = gate.assess(SampleTeam.mods)
        XCTAssertEqual(a.filter { $0.verdict.loads }.map(\.id), ["secrets-redactor@acme-tools"])
    }

    func testAllowManagedModsOnlyIsInertWithoutTheGuard() {
        // Same option, but prependPlugins drops the guard, so the option has nothing to run in.
        var gate = SampleTeam.defaultGate
        gate.settings.allowManagedModsOnly = true
        gate.settings.prependPlugins = ["secrets-redactor@acme-tools"]
        XCTAssertEqual(GateSummary(gate.assess(SampleTeam.mods)).loaded, 10)
    }

    func testDisableSideloadFlagsRefusesSessionWrittenMod() throws {
        var gate = SampleTeam.defaultGate
        gate.settings.disableSideloadFlags = true
        let scratch = try XCTUnwrap(gate.assess(SampleTeam.mods).first { $0.id == "scratch-mod" })
        XCTAssertFalse(scratch.verdict.loads)
    }

    func testEmptyRegistry() {
        XCTAssertEqual(GateSummary(SampleTeam.leadGate.assess([])).loaded, 0)
    }
}

final class DenyCoverageTests: XCTestCase {
    func testDenyRuleParsing() {
        XCTAssertEqual(DenyRule("Read(.env)"), DenyRule(tool: "Read", pattern: ".env"))
        XCTAssertNil(DenyRule("Read()"))
        XCTAssertNil(DenyRule("(.env)"))
        XCTAssertNil(DenyRule("Read"))
    }

    func testSixOfTenLoadedModsReachEnvByDefault() {
        let g = SampleTeam.defaultGate
        let e = DenyCoverage.exposures(rule: SampleTeam.envRule, assessments: g.assess(SampleTeam.mods),
                                       settings: g.settings, plan: g.plan)
        XCTAssertEqual(e.count, 6)
        // With the guard loaded, the auto-approver can't override the deny rule.
        XCTAssertFalse(e.contains { $0.modID == "swiftformat-autoapprove@community" })
    }

    func testWithoutTheGuardTheAutoApproverJoins() {
        var g = SampleTeam.defaultGate
        g.settings = .none
        g.plan = .personal
        let e = DenyCoverage.exposures(rule: SampleTeam.envRule, assessments: g.assess(SampleTeam.mods),
                                       settings: g.settings, plan: g.plan)
        XCTAssertEqual(e.count, 7)
        XCTAssertEqual(e.first { $0.modID == "swiftformat-autoapprove@community" }?.paths, [.approvesDeniedCall])
    }

    func testOverrideOptionReopensTheApprovalPath() {
        var g = SampleTeam.defaultGate
        g.settings.allowModsToOverrideDenyRules = true
        let e = DenyCoverage.exposures(rule: SampleTeam.envRule, assessments: g.assess(SampleTeam.mods),
                                       settings: g.settings, plan: g.plan)
        XCTAssertTrue(e.contains { $0.modID == "swiftformat-autoapprove@community" })
    }

    func testLeadPolicyLeavesOnlyTwoReviewedModsWithReach() {
        let g = SampleTeam.leadGate
        let e = DenyCoverage.exposures(rule: SampleTeam.envRule, assessments: g.assess(SampleTeam.mods),
                                       settings: g.settings, plan: g.plan)
        XCTAssertEqual(e.map(\.modID), ["secrets-redactor@acme-tools", "xcode-build-digest@ios-guild"])
    }
}

final class SHA256Tests: XCTestCase {
    func testKnownVectors() {
        XCTAssertEqual(SHA256.hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // Two-block message (56 bytes forces a second padding block).
        XCTAssertEqual(SHA256.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }
}
