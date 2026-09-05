import SwiftUI

struct OrbView: View {
    @Environment(AppState.self) private var appState
    let atmosphere: FeatureAtmosphere
    var progress: Double?
    var size: CGFloat = 250
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 10 : 1 / 30)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate

            ZStack {
                Circle()
                    .fill(atmosphere.glow.opacity(0.32))
                    .blur(radius: 42)
                    .scaleEffect(1.02 + 0.035 * sin(t * 0.9))

                if appState.theme == .space {
                    ForEach(0..<2) { ring in
                        Circle()
                            .stroke(
                                atmosphere.accent.opacity(ring == 0 ? 0.19 : 0.09),
                                style: StrokeStyle(lineWidth: 1, dash: ring == 0 ? [3, 8] : [1, 13])
                            )
                            .padding(CGFloat(-17 - ring * 12))
                            .rotationEffect(.degrees(t * (ring == 0 ? 5 : -3)))
                    }

                    Image(spaceAsset: "sun")
                        .resizable()
                        .scaledToFit()
                        .rotationEffect(.degrees(t * 0.72))
                        .scaleEffect(0.96 + 0.018 * sin(t * 1.15))
                        .shadow(color: Color(hex: 0xFF7A24, opacity: 0.48), radius: 26)
                } else {
                    Ellipse()
                        .fill(Color.black.opacity(0.28))
                        .frame(width: size * 0.72, height: size * 0.18)
                        .blur(radius: 9)
                        .offset(y: size * 0.32)

                    Image(spaceAsset: woodlandHeroAsset)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(woodlandHeroScale)
                        .shadow(color: atmosphere.glow.opacity(0.52), radius: 24, y: 10)
                }

                if let progress {
                    Circle()
                        .trim(from: 0, to: max(0.01, progress))
                        .stroke(.white.opacity(0.94), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(-13)
                        .shadow(color: atmosphere.accent.opacity(0.8), radius: 7)
                }
            }
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: reduceMotion ? 0 : 0.35), value: appState.theme)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Operation progress")
        .accessibilityValue(progress.map { "\(Int($0 * 100)) percent" } ?? "Ready")
    }

    private var woodlandHeroAsset: String {
        switch appState.selection {
        case .optimize: "woodland-owl"
        case .analyze: "woodland-hedgehog"
        default: "woodland-mole"
        }
    }

    private var woodlandHeroScale: CGFloat {
        switch appState.selection {
        case .optimize: 1.3
        case .analyze: 1.22
        default: 1.16
        }
    }

}
