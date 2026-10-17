import AppKit

/// WCAG 2 contrast, for a test that holds something drawn to the ratio a person
/// needs to make it out: 3:1 for a mark or a control's edge (WCAG 1.4.11),
/// 4.5:1 for body text (1.4.3).
public enum ContrastRatio {
    /// The ratio between two colours, from 1 (the same) to 21 (black on white),
    /// or nil when either has no sRGB form. A translucent colour is laid over
    /// white first, the way it would be seen on a light card.
    public static func between(_ first: NSColor, _ second: NSColor) -> Double? {
        guard let one = luminance(of: first), let other = luminance(of: second) else { return nil }
        return (max(one, other) + 0.05) / (min(one, other) + 0.05)
    }

    /// WCAG relative luminance, or nil when the colour has no sRGB form.
    public static func luminance(of colour: NSColor) -> Double? {
        guard let rgb = colour.usingColorSpace(.sRGB) else { return nil }
        let alpha = Double(rgb.alphaComponent)
        func linear(_ channel: CGFloat) -> Double {
            let value = Double(channel) * alpha + (1 - alpha)
            return value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.212_6 * linear(rgb.redComponent) + 0.715_2 * linear(rgb.greenComponent)
            + 0.072_2 * linear(rgb.blueComponent)
    }
}
