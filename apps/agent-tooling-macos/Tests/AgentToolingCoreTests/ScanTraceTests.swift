import Foundation
import Testing
import os

@testable import AgentToolingCore

/// The trace a read reports its places to: free when nothing listens, heard
/// by every task the read starts, and told to every recorder listening.
@Suite("Scan trace")
struct ScanTraceTests {
    private static let place = URL(filePath: "/Users/example/.codex/config.toml")

    /// With no recorder, a hook does not even build the place it would
    /// report.
    @Test func withNoRecorderNothingIsBuilt() {
        let built = OSAllocatedUnfairLock(initialState: false)
        func place() -> URL {
            built.withLock { $0 = true }
            return Self.place
        }

        ScanTrace.read(place())

        #expect(!built.withLock { $0 })
    }

    /// The recorder reaches every task a read starts inside it: `async let`,
    /// a task group, and `Task { }`. A detached task is outside the read.
    @Test func everyTaskARecordingStartsReportsToIt() async {
        let trace = FirstReadPlaceLog()
        let places = (0..<4).map { URL(filePath: "/Users/example/place-\($0)") }

        await ScanTrace.$current.withValue(trace) {
            async let child: Void = ScanTrace.read(places[0])
            await child
            await withTaskGroup(of: Void.self) { group in
                group.addTask { ScanTrace.read(places[1]) }
            }
            await Task { ScanTrace.read(places[2]) }.value
            await Task.detached { ScanTrace.read(places[3]) }.value
        }

        #expect(Set(trace.places) == Set(places.prefix(3)))
    }

    /// A recording made inside another reports to both, so a trace set
    /// around a first read still hears what the read touches.
    @Test func aRecordingInsideAnotherReportsToBoth() async {
        let outer = FirstReadPlaceLog()
        let inner = FirstReadPlaceLog()

        await ScanTrace.$current.withValue(outer) {
            await ScanTrace.recording(into: inner) { ScanTrace.read(Self.place) }
            ScanTrace.read(URL(filePath: "/Users/example/after"))
        }

        #expect(inner.places == [Self.place])
        #expect(outer.places == [Self.place, URL(filePath: "/Users/example/after")])
    }

    /// Reports from many tasks at once all land.
    @Test func reportsFromManyTasksAtOnceAllLand() async {
        let trace = FirstReadPlaceLog()

        await ScanTrace.$current.withValue(trace) {
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<200 {
                    group.addTask { ScanTrace.read(URL(filePath: "/Users/example/place-\(index)")) }
                }
            }
        }

        #expect(Set(trace.places).count == 200)
    }
}
