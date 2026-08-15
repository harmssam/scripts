import Testing
@testable import Pulse

@Suite("Popover metrics snapshot")
struct PopoverMetricsTests {
    @Test("identical snapshots compare equal")
    func identicalSnapshotsAreEqual() {
        #expect(PopoverMetrics() == PopoverMetrics())

        var changed = PopoverMetrics()
        changed.diskReadRate = 1
        #expect(PopoverMetrics() != changed)
    }
}
