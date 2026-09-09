import Foundation
import Testing

@testable import AgentToolingCore

/// The inspector explains what a client will use and why. It writes nothing,
/// keeps unknown fields visible, and never presents a value as effective when a
/// higher layer constrains it.
@Suite("Effective configuration")
struct EffectiveConfigurationResolverTests {
    @Test func policyWinsAndTheLayerUnderneathIsShownAsOverridden() {
        let result = EffectiveConfigurationResolver.resolve(
            adapter: ClaudeCodeConfigurationAdapter(), installedClientVersion: "2.0.0",
            layers: [
                .init(kind: .managedPolicy, sourcePath: "/policy", isWritable: false,
                      values: ["model": .string("policy-model")]),
                .init(kind: .project, sourcePath: "/project", isWritable: true,
                      values: ["model": .string("project-model")]),
                .init(kind: .user, sourcePath: "/user", isWritable: true,
                      values: ["model": .string("user-model")]),
            ])

        let model = result.rows.first { $0.key == "model" }
        #expect(model?.value == .string("policy-model"))
        #expect(model?.definedBy == .managedPolicy)
        #expect(model?.contributions.map(\.layer) == [.managedPolicy, .project, .user])
        #expect(model?.contributions.filter(\.isOverridden).map(\.layer) == [.project, .user])
        // Writing a lower layer cannot change what the client uses.
        #expect(model?.writableLayer == nil)
        #expect(model?.isConstrained == true)
        #expect(model?.requiresNewSession == true)
    }

    @Test func aWritableLayerAtOrAboveTheWinnerStaysEditable() {
        let result = EffectiveConfigurationResolver.resolve(
            adapter: ClaudeCodeConfigurationAdapter(), installedClientVersion: "2.0.0",
            layers: [
                .init(kind: .project, sourcePath: "/project", isWritable: true,
                      values: ["model": .string("project-model")]),
                .init(kind: .user, sourcePath: "/user", isWritable: true,
                      values: ["model": .string("user-model")]),
            ])

        let model = result.rows.first { $0.key == "model" }
        #expect(model?.value == .string("project-model"))
        #expect(model?.writableLayer == .project)
        #expect(model?.isConstrained == false)
    }

    @Test func hookAndPermissionListsCombineRatherThanReplace() {
        let result = EffectiveConfigurationResolver.resolve(
            adapter: ClaudeCodeConfigurationAdapter(), installedClientVersion: "2.0.0",
            layers: [
                .init(kind: .project, sourcePath: "/project", isWritable: true,
                      values: ["permissions.allow": .list([.string("Bash(git:*)")])]),
                .init(kind: .user, sourcePath: "/user", isWritable: true,
                      values: ["permissions.allow": .list([.string("Read"), .string("Grep")])]),
            ])

        let allowed = result.rows.first { $0.key == "permissions.allow" }
        #expect(allowed?.rule == .combineList)
        #expect(allowed?.value == .list([.string("Bash(git:*)"), .string("Read"), .string("Grep")]))
        // A combining setting has no overridden contribution: both apply.
        #expect(allowed?.contributions.allSatisfy { !$0.isOverridden } == true)
    }

    @Test func unknownFieldsStayVisibleWithoutBecomingEffective() {
        let result = EffectiveConfigurationResolver.resolve(
            adapter: ClaudeCodeConfigurationAdapter(), installedClientVersion: "2.0.0",
            layers: [
                .init(kind: .user, sourcePath: "/user", isWritable: true,
                      values: ["model": .string("user-model")],
                      unrecognizedKeys: ["experimentalThing", "vendorExtension"]),
            ])

        #expect(result.unrecognized.map(\.key) == ["experimentalThing", "vendorExtension"])
        #expect(result.unrecognized.allSatisfy { $0.layer == .user })
        #expect(!result.rows.contains { $0.key == "experimentalThing" })
    }

    @Test func aLayerTheInstalledVersionDoesNotReadIsVisibleButNeverEffective() {
        // Codex has no managed-policy layer; a file there must not decide.
        let result = EffectiveConfigurationResolver.resolve(
            adapter: CodexConfigurationAdapter(installedClientVersion: "0.140.0"),
            installedClientVersion: "0.140.0",
            layers: [
                .init(kind: .managedPolicy, sourcePath: "/policy", isWritable: false,
                      values: ["model": .string("policy-model")]),
                .init(kind: .user, sourcePath: "/config.toml", isWritable: true,
                      values: ["model": .string("user-model")]),
            ])

        #expect(result.rows.first { $0.key == "model" }?.value == .string("user-model"))
        #expect(result.inactiveLayers == [.managedPolicy])
        #expect(result.surface == .codexCLI)
    }

    @Test func codexProfileLayoutFollowsTheInstalledRelease() {
        #expect(CodexConfigurationAdapter(installedClientVersion: "0.133.9").usesSeparateProfileFiles == false)
        #expect(CodexConfigurationAdapter(installedClientVersion: "0.134.0").usesSeparateProfileFiles)
        #expect(CodexConfigurationAdapter(installedClientVersion: "0.140.2").usesSeparateProfileFiles)
        #expect(CodexConfigurationAdapter(installedClientVersion: "v1.2.0").usesSeparateProfileFiles)
        // An unknown or unreadable version claims neither layout.
        #expect(CodexConfigurationAdapter(installedClientVersion: nil).usesSeparateProfileFiles == false)
        #expect(CodexConfigurationAdapter(installedClientVersion: "nightly").usesSeparateProfileFiles == false)
    }

    @Test func unknownSessionOverridesAreStatedRatherThanAssumedAway() {
        let unknown = EffectiveConfigurationResolver.resolve(
            adapter: ClaudeCodeConfigurationAdapter(), installedClientVersion: nil,
            layers: [.init(kind: .user, sourcePath: "/user", isWritable: true,
                           values: ["model": .string("user-model")])])
        #expect(unknown.sessionOverridesUnknown)
        #expect(unknown.summary == "Expected from local configuration; session overrides unknown.")

        let observed = EffectiveConfigurationResolver.resolve(
            adapter: ClaudeCodeConfigurationAdapter(), installedClientVersion: "2.0.0",
            layers: [.init(kind: .session, sourcePath: nil, isWritable: false,
                           values: ["model": .string("session-model")]),
                     .init(kind: .user, sourcePath: "/user", isWritable: true,
                           values: ["model": .string("user-model")])],
            sessionOverridesUnknown: false)
        #expect(observed.rows.first { $0.key == "model" }?.value == .string("session-model"))
        #expect(observed.rows.first { $0.key == "model" }?.writableLayer == nil)
        #expect(observed.summary == "Effective for new sessions.")
    }

    @Test func aSettingAbsentFromEveryLayerHasNoRow() {
        let result = EffectiveConfigurationResolver.resolve(
            adapter: ClaudeCodeConfigurationAdapter(), installedClientVersion: "2.0.0",
            layers: [.init(kind: .user, sourcePath: "/user", isWritable: true, values: [:])])
        #expect(result.rows.isEmpty)
    }
}
