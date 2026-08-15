import SwiftUI
import AppKit

struct FanAnimation: View {
    let fan: Fan
    let date: Date

    private static let templatedFanImage: NSImage? = {
        if let image = Bundle.module.image(forResource: "fan") {
            image.isTemplate = true
            return image
        }
        return nil
    }()

    @State private var eggRotation: Double = 0

    /// rpm < 250 → 0; rpm < 2000 → 0.4 (small); else 0.8 (medium)
    nonisolated static func blurRadius(rpm: Double) -> Double {
        if rpm < 250 { return 0 }
        if rpm < 2000 { return 0.4 }
        return 0.8
    }

    static func rotationDegrees(rpm: Double, date: Date) -> Double {
        let normalized = min(max(rpm, 0) / 5200.0, 1.8)
        let degreesPerSecond = normalized * 19.0 * 30.0
        return (date.timeIntervalSinceReferenceDate * degreesPerSecond)
            .truncatingRemainder(dividingBy: 360)
    }

    var body: some View {
        VStack(spacing: 1) {
            fanGlyph
                .onTapGesture {
                    triggerEasterEggSpin()
                }

            Text("fan-\(fan.id + 1)")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text("\(SafeNumeric.roundedInt(fan.currentRPM))")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.orange)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var fanGlyph: some View {
        let rotation = Self.rotationDegrees(rpm: fan.currentRPM, date: date) + eggRotation
        if let nsImage = Self.templatedFanImage {
            spunImage(
                Image(nsImage: nsImage),
                rotation: rotation
            )
            .opacity(0.92)
        } else {
            spunImage(
                Image(systemName: "fanblades"),
                rotation: rotation
            )
        }
    }

    @ViewBuilder
    private func spunImage(_ image: Image, rotation: Double) -> some View {
        let radius = Self.blurRadius(rpm: fan.currentRPM)
        let view = image
            .resizable()
            .scaledToFit()
            .frame(width: 28, height: 28)
            .foregroundStyle(.orange)
            .rotationEffect(.degrees(rotation))
        if radius > 0 {
            view.blur(radius: radius)
        } else {
            view
        }
    }

    private func triggerEasterEggSpin() {
        withAnimation(.linear(duration: 0.4)) {
            eggRotation += 360 * 8
        }
        withAnimation(.easeOut(duration: 4.0).delay(0.4)) {
            eggRotation += 360 * 4
        }
    }
}
