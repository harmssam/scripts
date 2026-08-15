import Testing
@testable import Pulse

@Suite("Fan blur bands")
struct FanAnimationTests {
    @Test("rpm below 250 has no blur")
    func idleHasNoBlur() {
        #expect(FanAnimation.blurRadius(rpm: 0) == 0)
        #expect(FanAnimation.blurRadius(rpm: 249) == 0)
    }

    /// 250..<2000 → 0.4 (small); 2000+ → 0.8 (medium)
    @Test("rpm bands map to small and medium blur")
    func blurBands() {
        #expect(FanAnimation.blurRadius(rpm: 250) == 0.4)
        #expect(FanAnimation.blurRadius(rpm: 1999) == 0.4)
        #expect(FanAnimation.blurRadius(rpm: 2000) == 0.8)
        #expect(FanAnimation.blurRadius(rpm: 6000) == 0.8)
    }
}
