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

    @Test("applyRates writes disk rates into popover cache")
    func applyRatesPublishesDisk() {
        let rates = RefreshRates(
            downloadRate: 10,
            uploadRate: 20,
            diskReadRate: 111,
            diskWriteRate: 222
        )
        let updated = PopoverMetrics().applying(rates: rates)
        #expect(updated.diskReadRate == 111)
        #expect(updated.diskWriteRate == 222)
    }

    @Test("history uses latest applyRates, not the kick-tick snapshot")
    func historyUsesLatestRates() {
        let kick = RefreshRates(downloadRate: 1, uploadRate: 2, diskReadRate: 3, diskWriteRate: 4)
        let latest = RefreshRates(downloadRate: 10, uploadRate: 20, diskReadRate: 30, diskWriteRate: 40)
        let used = AppState.historyRates(latest: latest, kickTick: kick)
        #expect(used.downloadRate == 10)
        #expect(used.uploadRate == 20)
        #expect(used.diskReadRate == 30)
        #expect(used.diskWriteRate == 40)
    }

    @Test("popover show kick includes processes")
    func popoverShowKickIncludesProcesses() {
        #expect(AppState.shouldIncludeProcesses(isPopoverShown: false, pendingShowKick: false) == false)
        #expect(AppState.shouldIncludeProcesses(isPopoverShown: false, pendingShowKick: true) == true)
        #expect(AppState.shouldIncludeProcesses(isPopoverShown: true, pendingShowKick: false) == true)
    }
}
