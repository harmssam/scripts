import Testing
@testable import Pulse

@Suite("Thermal monitor key cache")
struct ThermalMonitorTests {
    actor KeyRecorder {
        private(set) var keys: [String] = []

        func record(_ key: String) {
            keys.append(key)
        }

        func take() -> [String] {
            let copy = keys
            keys = []
            return copy
        }
    }

    @Test("Second sample only rereads keys that returned in-range values")
    func cachesWorkingTemperatureKeys() async {
        let recorder = KeyRecorder()
        let monitor = ThermalMonitor(sampleInterval: 0) { key in
            await recorder.record(key)
            if key == "Tp09" || key == "Tg05" { return 55.0 }
            return nil
        }

        let first = await monitor.sample()
        let firstKeys = await recorder.take()
        #expect(first.temp.cpuTemperature == 55.0)
        #expect(first.temp.gpuTemperature == 55.0)
        #expect(firstKeys.count > 20)
        #expect(firstKeys.contains("Tp09"))
        #expect(firstKeys.contains("Tg05"))

        let second = await monitor.sample()
        let secondKeys = await recorder.take()
        #expect(second.temp.cpuTemperature == 55.0)
        #expect(second.temp.gpuTemperature == 55.0)
        #expect(Set(secondKeys) == Set(["Tp09", "Tg05"]))
        #expect(secondKeys.count == 2)
    }

    @Test("Duplicate temperature keys are requested once")
    func deduplicatesProbeKeys() async {
        let recorder = KeyRecorder()
        let monitor = ThermalMonitor(sampleInterval: 0) { key in
            await recorder.record(key)
            return nil
        }

        _ = await monitor.sample()
        let keys = await recorder.take()
        let tg0jCount = keys.filter { $0 == "Tg0j" }.count
        #expect(tg0jCount == 1)
        #expect(Set(keys).count == keys.count)
    }
}
