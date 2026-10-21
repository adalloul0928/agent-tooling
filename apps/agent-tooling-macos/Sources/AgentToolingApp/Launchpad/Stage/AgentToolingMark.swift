import SwiftUI

/// Native geometry matching `Resources/AppIcon.svg` in its 1024-point coordinates.
/// Tests keep the artwork aligned. Stage shadows differ from Dock shadows;
/// the icon's blue is confined to the mark, not the app's semantic palette.
enum AgentToolingMarkArtwork {
    static let viewBox: CGFloat = 1024

    /// The outer plate.
    static let plate = CGRect(x: 92, y: 70, width: 840, height: 840)
    static let plateRadius: CGFloat = 194
    static let plateColour: UInt32 = 0xE7E7E4

    /// The inner plate and the white line around it.
    static let innerPlate = CGRect(x: 105, y: 83, width: 814, height: 814)
    static let innerPlateRadius: CGFloat = 181
    static let innerPlateColour: UInt32 = 0xF4F4F2
    static let innerPlateStroke: CGFloat = 14

    /// The face the tracks sit on: white at part strength, with a faint edge.
    static let face = CGRect(x: 156, y: 144, width: 712, height: 684)
    static let faceRadius: CGFloat = 128
    static let faceOpacity = 0.54
    static let faceStrokeColour: UInt32 = 0x111111
    static let faceStrokeOpacity = 0.08
    static let faceStroke: CGFloat = 4

    /// The three tracks.
    static let trackY: [CGFloat] = [340, 486, 632]
    static let trackStart: CGFloat = 252
    static let trackEnd: CGFloat = 772
    static let trackWidth: CGFloat = 34
    static let ink: UInt32 = 0x27272A
    static let trackOpacity = 0.30

    /// The three knobs, each at rest on its track, and the shadow the stage
    /// draws under each: dropped as far as the icon file's, and a blur's
    /// deviation of 5 (the mockups' `drop-shadow(0 9px 10px)`), at 20%.
    static let knobX: [CGFloat] = [400, 644, 492]
    static let knobRadius: CGFloat = 59
    static let knobColour: UInt32 = 0xFAFAF9
    static let knobStroke: CGFloat = 7
    static let knobStrokeOpacity = 0.24
    static let knobShadowY: CGFloat = 9
    static let knobShadowBlur: CGFloat = 5
    static let knobShadowOpacity = 0.20

    /// The dot in each knob: the first in the icon blue, the others in ink.
    static let dotRadius: CGFloat = 22
    static let knobBlue: UInt32 = 0x0A84FF

    /// The highlight across the top of the face.
    static let highlightStart = CGPoint(x: 190, y: 216)
    static let highlightControl1 = CGPoint(x: 310, y: 126)
    static let highlightControl2 = CGPoint(x: 714, y: 112)
    static let highlightEnd = CGPoint(x: 824, y: 250)
    static let highlightWidth: CGFloat = 18
    static let highlightOpacity = 0.68
}

/// Agent Tooling's own mark, drawn natively at any size. On Welcome its three
/// knobs slide from the start of their tracks to rest, one after another: the
/// one single motion on the stage longer than `AgentMotion.selection`. Under
/// Reduce Motion, and in a still, the knobs are drawn at rest.
///
/// VoiceOver reads it as one image, "Agent Tooling".
struct AgentToolingMark: View {
    var size: CGFloat = Size.heroMark
    /// Slide the knobs in when the mark appears.
    var animatesKnobs = false
    /// Cast the mark's Dock-icon shadows. Off where the mark sits small on a
    /// card (`AgentToolingAppMark`).
    var elevated = true
    @Environment(\.stageMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false

    private typealias Art = AgentToolingMarkArtwork

    var body: some View {
        let scale = size / Art.viewBox
        let atRest = settled || !(animatesKnobs && motion.resolved(reduceMotion: reduceMotion).animatesDetails)
        ZStack(alignment: .topLeading) {
            plates(scale)
            tracks(scale)
            ForEach(Art.knobX.indices, id: \.self) { index in
                knob(index, scale: scale, atRest: atRest)
            }
            highlight(scale)
        }
        .frame(width: size, height: size)
        .modifier(MarkElevation(isOn: elevated))
        .accessibilityElement()
        .accessibilityLabel(LaunchpadCopy.Kit.markLabel)
        .accessibilityAddTraits(.isImage)
        .onAppear {
            guard animatesKnobs, !settled else { return }
            settled = true
        }
    }

    private func plates(_ scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Art.plateRadius * scale, style: .continuous)
                .fill(Color(nsColor: NSColor(hex: Art.plateColour)))
                .frame(width: Art.plate.width * scale, height: Art.plate.height * scale)
                .offset(x: Art.plate.minX * scale, y: Art.plate.minY * scale)
            RoundedRectangle(cornerRadius: Art.innerPlateRadius * scale, style: .continuous)
                .fill(Color(nsColor: NSColor(hex: Art.innerPlateColour)))
                .overlay {
                    RoundedRectangle(cornerRadius: Art.innerPlateRadius * scale, style: .continuous)
                        .stroke(.white, lineWidth: Art.innerPlateStroke * scale)
                }
                .frame(width: Art.innerPlate.width * scale, height: Art.innerPlate.height * scale)
                .offset(x: Art.innerPlate.minX * scale, y: Art.innerPlate.minY * scale)
            RoundedRectangle(cornerRadius: Art.faceRadius * scale, style: .continuous)
                .fill(.white.opacity(Art.faceOpacity))
                .overlay {
                    RoundedRectangle(cornerRadius: Art.faceRadius * scale, style: .continuous)
                        .stroke(
                            Color(nsColor: NSColor(hex: Art.faceStrokeColour)).opacity(Art.faceStrokeOpacity),
                            lineWidth: Art.faceStroke * scale)
                }
                .frame(width: Art.face.width * scale, height: Art.face.height * scale)
                .offset(x: Art.face.minX * scale, y: Art.face.minY * scale)
        }
    }

    private func tracks(_ scale: CGFloat) -> some View {
        Path { path in
            for y in Art.trackY {
                path.move(to: CGPoint(x: Art.trackStart * scale, y: y * scale))
                path.addLine(to: CGPoint(x: Art.trackEnd * scale, y: y * scale))
            }
        }
        .stroke(
            Color(nsColor: NSColor(hex: Art.ink)).opacity(Art.trackOpacity),
            style: StrokeStyle(lineWidth: Art.trackWidth * scale, lineCap: .round))
    }

    private func knob(_ index: Int, scale: CGFloat, atRest: Bool) -> some View {
        let restX = Art.knobX[index]
        let x = atRest ? restX : Art.trackStart
        let diameter = Art.knobRadius * 2 * scale
        let dot = Art.dotRadius * 2 * scale
        return ZStack {
            Circle()
                .fill(Color(nsColor: NSColor(hex: Art.knobColour)))
                .overlay {
                    Circle().stroke(
                        Color(nsColor: NSColor(hex: Art.ink)).opacity(Art.knobStrokeOpacity),
                        lineWidth: Art.knobStroke * scale)
                }
                .compositingGroup()
                .shadow(
                    color: .black.opacity(Art.knobShadowOpacity), radius: Art.knobShadowBlur * scale,
                    y: Art.knobShadowY * scale)
            Circle()
                .fill(Color(nsColor: NSColor(hex: index == 0 ? Art.knobBlue : Art.ink)))
                .frame(width: dot, height: dot)
        }
        .frame(width: diameter, height: diameter)
        .position(x: x * scale, y: Art.trackY[index] * scale)
        .animation(AgentMotion.knobSlide.delay(AgentMotion.knobDelays[index]), value: atRest)
    }

    private func highlight(_ scale: CGFloat) -> some View {
        Path { path in
            path.move(to: point(Art.highlightStart, scale))
            path.addCurve(
                to: point(Art.highlightEnd, scale), control1: point(Art.highlightControl1, scale),
                control2: point(Art.highlightControl2, scale))
        }
        .stroke(
            .white.opacity(Art.highlightOpacity),
            style: StrokeStyle(lineWidth: Art.highlightWidth * scale, lineCap: .round))
    }

    private func point(_ point: CGPoint, _ scale: CGFloat) -> CGPoint {
        CGPoint(x: point.x * scale, y: point.y * scale)
    }
}

/// The mark's Dock-icon shadows: a contact shadow and a cast one, so its
/// light plate keeps its edge on the near-white stage and stands off the
/// near-black one, deeper there.
private struct MarkElevation: ViewModifier {
    let isOn: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if isOn {
            let dark = colorScheme == .dark
            // One layer, so the mark casts one shadow: a shadow on its parts
            // would darken the translucent face through it.
            content
                .compositingGroup()
                .elevation(dark ? .markContactOnDark : .markContact)
                .elevation(dark ? .markCastOnDark : .markCast)
        } else {
            content
        }
    }
}
