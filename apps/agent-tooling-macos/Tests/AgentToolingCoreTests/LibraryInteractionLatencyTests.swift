import Foundation
import Testing

@testable import AgentToolingCore

/// Measures the two things a person waits on in the Library: building the index
/// behind it, and filtering it once it is warm.
///
/// Opt-in and Release-only by intent. The plan is explicit that hardware-
/// sensitive timings must not become brittle ordinary CI assertions, so nothing
/// here asserts the qualification target itself. It reports the measurement and
/// fails only on a ceiling so far above the target that only a real regression
/// could reach it.
///
///     swift test -c release --filter LibraryInteractionLatency \
///       # with AGENT_TOOLING_RUN_LATENCY=1
private let runsLatency =
    ProcessInfo.processInfo.environment["AGENT_TOOLING_RUN_LATENCY"] == "1"

/// From the plan: routine feedback within 100 ms, warm filter p95 under 150 ms.
private let routineFeedbackTarget = Duration.milliseconds(100)
private let warmFilterTarget = Duration.milliseconds(150)
/// Ten times the target. Passing this says nothing good; failing it says
/// something broke badly enough that no machine could be the explanation.
private let regressionCeiling = 10

@Suite("Library interaction latency")
struct LibraryInteractionLatencyTests {
    @Test("Building the library index stays far inside the routine-feedback ceiling",
          .enabled(if: runsLatency), arguments: [500, 5_000])
    func indexBuild(count: Int) throws {
        let snapshot = try Self.snapshot(count: count)
        // One warm-up, so the measurement is the steady state a person sees
        // rather than first-touch cost.
        _ = try WorkspaceLibraryReadModel(snapshot: snapshot)

        let elapsed = try Self.median(of: 5) {
            _ = try WorkspaceLibraryReadModel(snapshot: snapshot)
        }

        Self.report("index build", count: count, elapsed: elapsed, target: routineFeedbackTarget)
        #expect(elapsed < routineFeedbackTarget * regressionCeiling,
                "Building \(count) rows took \(elapsed), far past anything hardware explains.")
    }

    @Test("Filtering a warm library stays far inside the warm-response ceiling",
          .enabled(if: runsLatency), arguments: [500, 5_000])
    func warmFilter(count: Int) throws {
        let model = try WorkspaceLibraryReadModel(snapshot: try Self.snapshot(count: count))
        _ = model.filteredRows(matching: "skill 4")

        let elapsed = Self.median(of: 9) {
            _ = model.filteredRows(matching: "skill 4")
        }

        Self.report("warm filter", count: count, elapsed: elapsed, target: warmFilterTarget)
        #expect(elapsed < warmFilterTarget * regressionCeiling,
                "Filtering \(count) rows took \(elapsed), far past anything hardware explains.")
    }

    /// Median rather than mean: one scheduling hiccup should not become the
    /// number, and a median of an odd count needs no interpolation.
    private static func median(of runs: Int, _ body: () throws -> Void) rethrows -> Duration {
        var samples: [Duration] = []
        for _ in 0..<runs {
            let start = ContinuousClock.now
            try body()
            samples.append(ContinuousClock.now - start)
        }
        return samples.sorted()[runs / 2]
    }

    private static func report(_ what: String, count: Int, elapsed: Duration, target: Duration) {
        let millis = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1e15
        let verdict = elapsed < target ? "within" : "over"
        // Printed rather than asserted: the plan wants these calibrated on
        // supported hardware, not enforced by whatever machine ran the suite.
        print("LATENCY \(what) n=\(count): \(String(format: "%.1f", millis)) ms (\(verdict) target)")
    }

    private static func snapshot(count: Int) throws -> WorkspaceApplicationSnapshot {
        let workspaceID = WorkspaceObjectID()
        let artifacts = (0..<count).map { offset in
            ArtifactRecord(
                identity: .init(id: ArtifactID(), kind: .skill, displayName: "Skill \(offset)"),
                authority: .centralPersonal, declaredName: "skill-\(offset)",
                contentDigest: .init(value: String(repeating: "a", count: 64)))
        }
        let document = try WorkspaceDocumentCoding.seal(.init(
            workspaceID: workspaceID, revision: .init(writerID: WorkspaceObjectID()),
            artifacts: artifacts))
        return .init(document: document, device: .init(workspaceID: workspaceID))
    }
}
