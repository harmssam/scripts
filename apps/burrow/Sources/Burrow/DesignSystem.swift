import AppKit
import SwiftUI

extension Bundle {
    static let burrowAssets: Bundle = {
        if let url = Bundle.main.url(forResource: "Burrow_Burrow", withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()
}

extension Image {
    init(spaceAsset name: String) {
        guard let url = Bundle.burrowAssets.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            assertionFailure("Missing space asset: \(name).png")
            self.init(systemName: "sparkles")
            return
        }
        self.init(nsImage: image)
    }
}

struct FeatureAtmosphere {
    let top: Color
    let bottom: Color
    let accent: Color
    let glow: Color

    static let clean = FeatureAtmosphere(
        top: Color(hex: 0x071B3D), bottom: Color(hex: 0x080A13),
        accent: Color(hex: 0x62C3FF), glow: Color(hex: 0x1674BD)
    )
    static let apps = FeatureAtmosphere(
        top: Color(hex: 0x35130F), bottom: Color(hex: 0x110B0D),
        accent: Color(hex: 0xF0886C), glow: Color(hex: 0x9E3E2D)
    )
    static let optimize = FeatureAtmosphere(
        top: Color(hex: 0x2C2608), bottom: Color(hex: 0x100E0A),
        accent: Color(hex: 0xE4C36F), glow: Color(hex: 0x8A731B)
    )
    static let analyze = FeatureAtmosphere(
        top: Color(hex: 0x3A1B0B), bottom: Color(hex: 0x120C0B),
        accent: Color(hex: 0xE7B76E), glow: Color(hex: 0xA8582A)
    )
    static let status = FeatureAtmosphere(
        top: Color(hex: 0x2D2608), bottom: Color(hex: 0x0E0C08),
        accent: Color(hex: 0x67D8A3), glow: Color(hex: 0x849A27)
    )
    static let woodland = FeatureAtmosphere(
        top: Color(hex: 0x173529), bottom: Color(hex: 0x090F0C),
        accent: Color(hex: 0xA8D878), glow: Color(hex: 0x4D8B58)
    )
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: opacity
        )
    }
}

enum BurrowType {
    static let hero = Font.system(size: 38, weight: .semibold, design: .rounded)
    static let metric = Font.system(size: 32, weight: .bold, design: .monospaced)
    static let title = Font.system(size: 16, weight: .semibold, design: .rounded)
    static let body = Font.system(size: 13, weight: .regular, design: .rounded)
    static let data = Font.system(size: 12, weight: .medium, design: .monospaced)
    static let label = Font.system(size: 10, weight: .bold, design: .monospaced)
}

struct PanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.09), lineWidth: 1)
            }
    }
}

extension View {
    func burrowPanel() -> some View { modifier(PanelModifier()) }
}

struct PrimaryCapsuleButtonStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.86))
            .padding(.horizontal, 30)
            .frame(height: 46)
            .background(accent.opacity(configuration.isPressed ? 0.72 : 1), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct FeatureCanvas<Content: View>: View {
    let atmosphere: FeatureAtmosphere
    let theme: AppTheme
    let section: AppSection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            LinearGradient(colors: [atmosphere.top, atmosphere.bottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(
                colors: [atmosphere.glow.opacity(0.2), .clear],
                center: .topTrailing, startRadius: 20, endRadius: 620
            )
            if theme == .space {
                SpaceBackdrop(atmosphere: atmosphere, reduceMotion: reduceMotion)
                    .transition(.opacity)
            } else {
                WoodlandBackdrop(atmosphere: atmosphere, section: section)
                    .transition(.opacity)
            }
            content
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: reduceMotion ? 0 : 0.45), value: theme)
    }
}

private struct WoodlandBackdrop: View {
    let atmosphere: FeatureAtmosphere
    let section: AppSection

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                for index in 0..<42 {
                    let x = pseudo(index * 47) * size.width
                    let y = pseudo(index * 83 + 7) * size.height
                    let radius = 1 + pseudo(index * 19) * 2
                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: radius, height: radius)),
                        with: .color(index.isMultiple(of: 3)
                            ? Color(hex: 0xF6D878, opacity: 0.14)
                            : atmosphere.accent.opacity(0.09))
                    )
                }
            }

            decorativeArt(in: proxy.size)

            LinearGradient(
                colors: [Color.black.opacity(0.14), .clear, Color.black.opacity(0.32)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func decorativeArt(in size: CGSize) -> some View {
        switch section {
        case .clean:
            Image(spaceAsset: "woodland-trees")
                .resizable().scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
                .opacity(0.24)
        case .apps:
            Image(spaceAsset: "woodland-fox")
                .resizable().scaledToFit()
                .frame(width: min(size.width * 0.34, 420))
                .scaleEffect(x: -1, y: 1)
                .offset(x: size.width * 0.69, y: size.height * 0.56)
                .opacity(0.66)
        case .optimize:
            EmptyView()
        case .analyze:
            Image(spaceAsset: "woodland-fawn")
                .resizable().scaledToFit()
                .frame(width: min(size.width * 0.28, 340))
                .offset(x: size.width * 0.76, y: size.height * 0.47)
                .opacity(0.58)
        case .status:
            Image(spaceAsset: "woodland-rabbit")
                .resizable().scaledToFit()
                .frame(width: min(size.width * 0.23, 280))
                .offset(x: size.width * 0.035, y: size.height * 0.55)
                .opacity(0.64)
        }
    }

    private func pseudo(_ seed: Int) -> CGFloat {
        CGFloat((seed * 73 + 41) % 997) / 997
    }
}

private struct SpaceBackdrop: View {
    let atmosphere: FeatureAtmosphere
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 10 : 1 / 24)) { timeline in
            GeometryReader { proxy in
                let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate

                Canvas { context, size in
                    for index in 0..<95 {
                        let x = pseudo(index * 71) * size.width
                        let y = pseudo(index * 43 + 9) * size.height
                        let pulse = 0.45 + 0.4 * sin(t * (0.25 + Double(index % 5) * 0.08) + Double(index))
                        let radius = 0.45 + pseudo(index * 13) * 1.15
                        context.fill(
                            Path(ellipseIn: CGRect(x: x, y: y, width: radius, height: radius)),
                            with: .color(.white.opacity(0.12 + pulse * 0.28))
                        )
                    }
                }

                Ellipse()
                    .stroke(atmosphere.accent.opacity(0.09), lineWidth: 1)
                    .frame(width: proxy.size.width * 0.72, height: proxy.size.height * 0.36)
                    .rotationEffect(.degrees(-11))
                    .offset(x: proxy.size.width * 0.35, y: proxy.size.height * 0.02)

                Image(spaceAsset: "ringed-planet")
                    .resizable().scaledToFit()
                    .frame(width: min(proxy.size.width * 0.25, 260))
                    .rotationEffect(.degrees(t * 0.32))
                    .offset(x: proxy.size.width * 0.78, y: proxy.size.height * 0.16)
                    .opacity(0.34)

                Image(spaceAsset: "moon")
                    .resizable().scaledToFit()
                    .frame(width: min(proxy.size.width * 0.11, 112))
                    .rotationEffect(.degrees(-t * 0.7))
                    .offset(x: proxy.size.width * 0.06, y: proxy.size.height * 0.72)
                    .opacity(0.38)

                if !reduceMotion {
                    Image(spaceAsset: "meteor")
                        .resizable().scaledToFit()
                        .blendMode(.screen)
                        .frame(width: 230)
                        .offset(
                            x: flyby(t, length: proxy.size.width + 480) - 260,
                            y: flyby(t * 0.61, length: proxy.size.height + 300) - 150
                        )
                        .opacity(flybyOpacity(t))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func pseudo(_ seed: Int) -> CGFloat {
        CGFloat((seed * 73 + 41) % 997) / 997
    }

    private func flyby(_ time: TimeInterval, length: CGFloat) -> CGFloat {
        CGFloat((time * 38).truncatingRemainder(dividingBy: Double(length)))
    }

    private func flybyOpacity(_ time: TimeInterval) -> Double {
        let phase = (time / 18).truncatingRemainder(dividingBy: 1)
        return phase < 0.46 ? sin(phase / 0.46 * .pi) * 0.44 : 0
    }
}
