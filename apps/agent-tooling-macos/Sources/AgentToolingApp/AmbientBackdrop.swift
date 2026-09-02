import SwiftUI

/// The calm four-hue desktop from the design pass, painted inside the window
/// so the glass sidebar has something to refract on any Mac. It drifts very
/// slowly and holds still under Reduce Motion.
struct AmbientBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            MeshGradient(width: 3, height: 3, points: points(at: time), colors: colors)
        }
        .overlay {
            LinearGradient(
                colors: [.white.opacity(colorScheme == .dark ? 0.10 : 0.28), .clear],
                startPoint: .topLeading,
                endPoint: .center
            )
        }
        .overlay(alignment: .topLeading) {
            // The glow the sidebar sits in, like the wallpaper's brightest corner.
            RadialGradient(
                colors: [Color(hex: 0x5B8CFF).opacity(colorScheme == .dark ? 0.22 : 0.12), .clear],
                center: .center,
                startRadius: 0,
                endRadius: 420
            )
            .frame(width: 840, height: 840)
            .offset(x: -300, y: -300)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var colors: [Color] {
        let palette: [UInt32] =
            colorScheme == .dark
            ? [0x2A4390, 0x1B2A5E, 0x33265F, 0x1A3F66, 0x0F1630, 0x38284F, 0x12414F, 0x1F2C44, 0x442D45]
            : [0xB4CEFA, 0xC9D8F6, 0xE2C9F6, 0xBBD8F0, 0xD6DDF0, 0xEDD2E6, 0xB2E2E8, 0xD3E0E8, 0xFBCFBC]
        return palette.map { Color(hex: $0) }
    }

    private func points(at time: TimeInterval) -> [SIMD2<Float>] {
        let t = Float(time)
        func drift(_ phase: Float, _ amplitude: Float, _ period: Float) -> Float {
            sin(t / period + phase) * amplitude
        }
        return [
            [0, 0], [0.5 + drift(0, 0.06, 11), 0], [1, 0],
            [0, 0.5 + drift(1.3, 0.06, 13)], [0.5 + drift(2.1, 0.09, 17), 0.5 + drift(0.7, 0.09, 15)], [1, 0.5 + drift(2.9, 0.06, 12)],
            [0, 1], [0.5 + drift(3.7, 0.06, 14), 1], [1, 1],
        ]
    }
}
