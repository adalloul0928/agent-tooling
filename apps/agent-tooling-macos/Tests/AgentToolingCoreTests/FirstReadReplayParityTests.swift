import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// The library setup makes from its first read is the library a first run
/// makes.
///
/// A first run scans the apps and writes what it found (`openOrCreate`).
/// Setup reads each chosen app in memory with `FirstRead`, then writes what it
/// read through a registry that replays it (`create` with `.replaying`). Over
/// the same Mac the two must hold the same workspace, apart from the
/// identifiers each creation mints and the moments each read was made; and
/// the replay must run nothing, because everything it needs was read already.
@Suite("First read · replay parity", .timeLimit(.minutes(5)))
struct FirstReadReplayParityTests {
    @Test(arguments: ClientHomeFixture.World.allCases)
    func aReplayedFirstReadMakesTheWorkspaceAFirstRunMakes(world kind: ClientHomeFixture.World) async throws {
        let world = try ClientHomeFixture(kind)
        defer { world.remove() }
        try world.plantDecoys()
        let support = try TemporaryFolder("first-read-replay-parity").url
        defer { try? FileManager.default.removeItem(at: support) }

        // A first run, scanning the apps this Mac has.
        let apps = ClientAdapterRegistry(adapters: world.registry.adapters.filter { world.found.contains($0.client) })
        let scanned = try await WorkspaceLocator(root: support.appending(path: "first-run")).openOrCreate(
            homeURL: world.url, runner: world.scriptedRunner(), registry: apps)

        // Setup's: each app read in memory, then replayed into a new store.
        let manifest = FirstReadManifest.build(chosen: world.found, homeURL: world.url, includeProjectHistory: true)
        var observations: [TargetObservation] = []
        for client in ClientKind.allCases where world.found.contains(client) {
            for await event in FirstRead.read(
                client, homeURL: world.url, manifest: manifest, runner: world.scriptedRunner(), registry: world.registry)
            {
                if case .finished(let observation) = event { observations.append(observation) }
            }
        }
        #expect(observations.count == world.found.count, "every chosen app's read finished")
        let replayRunner = ScriptedCommandRunner([:])
        let replayed = try await WorkspaceLocator(root: support.appending(path: "setup")).create(
            homeURL: world.url, runner: replayRunner, registry: .replaying(observations), preferences: nil)

        #expect(await replayRunner.launches.isEmpty, "the replay reads nothing and runs nothing")
        let first = try #require(try scanned.snapshot())
        let setup = try #require(try replayed.snapshot())
        #expect(Self.entries(first.document) == Self.entries(setup.document))
        #expect(Self.comparable(first.device) == Self.comparable(setup.device))
        #expect(setup.document.revision.parentIDs.isEmpty, "the replay's library starts at revision 1")
        if kind == .juniper {
            #expect(Self.entries(setup.document).filter { $0.parent == nil }.count == 8)
        }
    }

    /// One entry of a workspace, by what it is rather than by the identifier
    /// its creation minted: its parent is named by the parent's own name.
    struct Entry: Hashable, CustomStringConvertible {
        let kind: ArtifactKind
        let declaredName: String?
        let displayName: String
        let authority: ContentAuthority
        let routes: [NativePackageRoute]
        let relativePath: String?
        let digest: ContentDigest?
        let parent: String?

        var description: String { "\(kind) \(declaredName ?? displayName) in \(parent ?? "the library")" }
    }

    static func entries(_ document: PortableWorkspaceDocument) -> Set<Entry> {
        let names = Dictionary(document.artifacts.map { ($0.identity.id, $0.declaredName ?? $0.identity.displayName) }) { first, _ in first
        }
        return Set(
            document.artifacts.map { artifact in
                Entry(
                    kind: artifact.identity.kind, declaredName: artifact.declaredName, displayName: artifact.identity.displayName,
                    authority: artifact.authority, routes: artifact.nativeRoutes, relativePath: artifact.packageRelativePath,
                    digest: artifact.contentDigest, parent: artifact.identity.parentPackageID.flatMap { names[$0] })
            })
    }

    /// The device record with what differs between two creations set aside:
    /// the identifiers each minted, and when each read and each piece of
    /// evidence was observed.
    static func comparable(_ device: DeviceWorkspaceState) -> DeviceWorkspaceState {
        let moment = Date(timeIntervalSince1970: 0)
        var device = device
        device.workspaceID = WorkspaceObjectID(fixtureUUID("00000000-0000-0000-0000-000000000001"))
        device.deviceID = WorkspaceObjectID(fixtureUUID("00000000-0000-0000-0000-000000000002"))
        device.observations = device.observations.map { observation in
            var observation = observation
            observation.lastScannedAt = moment
            return observation
        }
        device.capabilityEvidence = device.capabilityEvidence
            .map { evidence in
                var evidence = evidence
                evidence.observedAt = moment
                return evidence
            }
            .sorted { String(describing: $0) < String(describing: $1) }
        return device
    }
}
