// Draws Finder artwork and its matching layout. With no arguments, updates
// Resources/DMG for the Info.plist version. Packaging uses:
//   swift scripts/render-dmg-layout.swift picture <version> <directory>

import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - The layout create-dmg.sh builds

/// Names and positions shared by the picture, the Finder layout and
/// create-dmg.sh. Points are Finder content coordinates: the origin is the
/// top-left of the window's content area.
enum DiskImage {
    static let volumeName = "Agent Tooling"
    static let appName = "Agent Tooling.app"
    static let applicationsName = "Applications"
    static let backgroundFolder = ".background"

    /// The picture's name carries the version it shows. The template's alias
    /// finds the picture by volume name and path, and with a second image
    /// mounted ("Agent Tooling 1") it tries the first ("Agent Tooling")
    /// before its own. Only an image of the same version holds this name, and
    /// that image's picture is the same one.
    static func backgroundName(version: String) -> String { "background-\(version).tiff" }

    static let content = CGSize(width: 640, height: 420)
    static let iconSize = 128.0
    static let labelSize = 13.0
    /// Icon centres.
    static let appIcon = CGPoint(x: 180, y: 170)
    static let applicationsIcon = CGPoint(x: 460, y: 170)

    /// A fresh HFS+ volume gives its first two items these catalog IDs (16
    /// and 17 belong to the file system's private folders). create-dmg.sh
    /// creates the picture's folder and then the picture before anything else,
    /// so the template's alias names them by ID as well as by path. The path
    /// alone also resolves: the volume is found by name, then the file by its
    /// path, even where another file holds ID 19.
    static let backgroundFolderID: UInt32 = 18
    static let backgroundFileID: UInt32 = 19
}

// MARK: - The picture

enum Picture {
    /// #767676, under the white caption at 4.54:1. One picture serves both
    /// appearances.
    static let ground = CGColor(srgbRed: 118 / 255, green: 118 / 255, blue: 118 / 255, alpha: 1)
    static let ink = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    /// Over a background picture, Finder on macOS 26.7.1 in Dark mode draws
    /// icon labels in black at 85 %, whatever the picture's brightness
    /// (measured on grounds #303030–#8C8C8C); Light mode is checked in WP11b
    /// §10.12. That ink reaches only 4.13:1 on #767676, so one band of
    /// #858585 runs under both labels (Finder sets them at y 248–260.5) and
    /// lifts them to 4.99:1. It runs 60 past each icon's centre, so neither
    /// icon reads as selected.
    static let labelBand = CGColor(srgbRed: 133 / 255, green: 133 / 255, blue: 133 / 255, alpha: 1)
    static let labelBandRect = CGRect(x: 120, y: 244, width: 400, height: 20)
    static let labelBandRadius = 6.0

    /// The dotted arc from the app to Applications: white at 40 %, 2 pt, dash
    /// 1 / 7, rising 14 between the icons. The open arrowhead is solid.
    static let arcStart = CGPoint(x: 262, y: 176)
    static let arcControl = CGPoint(x: 320, y: 148)
    static let arcEnd = CGPoint(x: 378, y: 176)
    static let arcOpacity = 0.40
    static let arcWidth = 2.0
    static let arcDash: [CGFloat] = [1, 7]
    static let arrowheadArm = 9.0
    static let arrowheadAngle = 40.0 * Double.pi / 180

    /// The slider-track watermark: the app icon's three tracks and knobs, as
    /// one flat white shape at 6 %, fitted into a 160 × 110 box whose
    /// bottom-right corner sits 40 in from the picture's. At 32 its middle
    /// track would touch the end of the caption's second line.
    static let watermarkOpacity = 0.06
    static let watermarkBox = CGRect(x: 640 - 40 - 160, y: 420 - 40 - 110, width: 160, height: 110)

    /// The caption, centred on the picture, with baselines at y 322 and 344.
    static let titleBaseline = 322.0
    static let detailBaseline = 344.0
    static let titleSize = 15.0
    static let detailSize = 11.0

    static func title() -> String { "Drag Agent Tooling to Applications" }

    static func detail(version: String) -> String {
        "Then open it from there. \(version) \u{00B7} Apple Silicon \u{00B7} macOS 26 or later"
    }

    /// Renders the picture at `scale` pixels per point.
    static func render(version: String, scale: Int) throws -> CGImage {
        let width = Int(DiskImage.content.width) * scale
        let height = Int(DiskImage.content.height) * scale
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw LayoutError("Could not create a \(width) × \(height) drawing context.") }

        // Draw in content points with the origin at the top-left, as Finder
        // places icons.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        context.setShouldAntialias(true)
        context.interpolationQuality = .high

        context.setFillColor(ground)
        context.fill(CGRect(origin: .zero, size: DiskImage.content))
        context.setFillColor(labelBand)
        context.addPath(
            CGPath(
                roundedRect: labelBandRect, cornerWidth: labelBandRadius, cornerHeight: labelBandRadius, transform: nil))
        context.fillPath()
        drawWatermark(in: context)
        drawArc(in: context)
        drawCaption(in: context, version: version)

        guard let image = context.makeImage() else { throw LayoutError("Could not finish the \(scale)x picture.") }
        return image
    }

    /// The curve and the head are stroked in one layer that is laid down at
    /// 40 %, so where the last dot meets the head's tip the white is laid
    /// down once, not twice.
    private static func drawArc(in context: CGContext) {
        context.saveGState()
        context.setAlpha(arcOpacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setStrokeColor(ink)
        context.setLineWidth(arcWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        context.setLineDash(phase: 0, lengths: arcDash)
        context.move(to: arcStart)
        context.addQuadCurve(to: arcEnd, control: arcControl)
        context.strokePath()

        // The head follows the curve's direction where it ends.
        context.setLineDash(phase: 0, lengths: [])
        let along = atan2(arcEnd.y - arcControl.y, arcEnd.x - arcControl.x)
        let back = along + Double.pi
        let left = CGPoint(
            x: arcEnd.x + arrowheadArm * cos(back - arrowheadAngle), y: arcEnd.y + arrowheadArm * sin(back - arrowheadAngle))
        let right = CGPoint(
            x: arcEnd.x + arrowheadArm * cos(back + arrowheadAngle), y: arcEnd.y + arrowheadArm * sin(back + arrowheadAngle))
        context.move(to: left)
        context.addLine(to: arcEnd)
        context.addLine(to: right)
        context.strokePath()
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// AppIcon.svg's slider face in its 1024 viewBox: tracks at y 340, 486
    /// and 632 from x 252 to 772, 34 wide with round caps; knobs of radius 59
    /// with a 7 pt rim at x 400, 644 and 492; each knob's 22 pt dot is knocked
    /// out so the knobs read as knobs, not blobs.
    private static func drawWatermark(in context: CGContext) {
        let trackY: [CGFloat] = [340, 486, 632]
        let knobX: [CGFloat] = [400, 644, 492]
        let trackStart: CGFloat = 252
        let trackEnd: CGFloat = 772
        let trackWidth: CGFloat = 34
        let knobRadius: CGFloat = 59 + 7 / 2
        let dotRadius: CGFloat = 22

        let motif = CGRect(
            x: trackStart - trackWidth / 2, y: trackY[0] - knobRadius,
            width: trackEnd - trackStart + trackWidth, height: trackY[2] - trackY[0] + 2 * knobRadius)
        let scale = min(watermarkBox.width / motif.width, watermarkBox.height / motif.height)
        let fitted = CGSize(width: motif.width * scale, height: motif.height * scale)
        // Right- and bottom-aligned in its box.
        let origin = CGPoint(x: watermarkBox.maxX - fitted.width, y: watermarkBox.maxY - fitted.height)
        func place(_ point: CGPoint) -> CGPoint {
            CGPoint(x: origin.x + (point.x - motif.minX) * scale, y: origin.y + (point.y - motif.minY) * scale)
        }

        context.saveGState()
        context.setAlpha(watermarkOpacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setStrokeColor(ink)
        context.setFillColor(ink)
        context.setLineCap(.round)
        context.setLineWidth(trackWidth * scale)
        for y in trackY {
            context.move(to: place(CGPoint(x: trackStart, y: y)))
            context.addLine(to: place(CGPoint(x: trackEnd, y: y)))
        }
        context.strokePath()
        for (x, y) in zip(knobX, trackY) {
            let centre = place(CGPoint(x: x, y: y))
            let radius = knobRadius * scale
            context.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius))
        }
        context.setBlendMode(.clear)
        for (x, y) in zip(knobX, trackY) {
            let centre = place(CGPoint(x: x, y: y))
            let radius = dotRadius * scale
            context.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius))
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private static func drawCaption(in context: CGContext, version: String) {
        drawCentredLine(title(), size: titleSize, weight: .semibold, baseline: titleBaseline, in: context)
        drawCentredLine(detail(version: version), size: detailSize, weight: .regular, baseline: detailBaseline, in: context)
    }

    private static func drawCentredLine(
        _ text: String, size: Double, weight: NSFont.Weight, baseline: Double, in context: CGContext
    ) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.saveGState()
        // The context is flipped; flip the glyphs back upright.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: (DiskImage.content.width - width) / 2, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Writes the 1x and 2x pictures without identifying image metadata.
    static func write(version: String, into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (scale, name) in [(1, "background.png"), (2, "background@2x.png")] {
            let image = try render(version: version, scale: scale)
            let url = directory.appending(path: name)
            guard
                let destination = CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { throw LayoutError("Could not write \(url.path).") }
            let dpi = 72 * scale
            let properties: [CFString: Any] = [
                kCGImagePropertyDPIWidth: dpi,
                kCGImagePropertyDPIHeight: dpi,
            ]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw LayoutError("Could not write \(url.path).") }
            try removeImageMetadata(at: url)
        }
    }

    // ImageIO emits EXIF alongside PNG density even without explicit EXIF fields.
    private static func removeImageMetadata(at url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw LayoutError("Invalid PNG output.") }
        var output = data.prefix(8)
        var offset = 8
        while offset < data.count {
            guard data.count - offset >= 12 else { throw LayoutError("Truncated PNG output.") }
            let count = data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            guard count <= data.count - offset - 12 else { throw LayoutError("Invalid PNG chunk length.") }
            let kind = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            let end = offset + count + 12
            if !["eXIf", "tEXt", "zTXt", "iTXt"].contains(kind) { output.append(data[offset..<end]) }
            offset = end
        }
        try output.write(to: url)
    }
}

// MARK: - The Finder layout (.DS_Store)

/// Finder's window and icon-view settings for the volume's root, plus each
/// item's place. Written as a .DS_Store: a buddy-allocated file holding one
/// B-tree leaf of records (Finder's own format; Mac::Finder::DSStore and the
/// ds_store Python module document it).
enum FinderLayout {
    /// The window's frame, measured from the screen's bottom-left: centred
    /// horizontally on a 1440 × 900 display, and Finder keeps it on screen on
    /// others. It includes the title bar, which is 32 pt with the toolbar
    /// hidden (macOS 26), so the content area is exactly the picture.
    static let titleBarHeight = 32.0
    static let windowOrigin = CGPoint(x: 400, y: 240)
    /// The sample world's moment, Sat 17 Oct 2026 9:41 UTC: a fixed date so
    /// the template is the same on every run. Finder matches the volume by
    /// name when no mounted volume has this creation date.
    static let fixedDate = Date(timeIntervalSince1970: 1_792_230_060)

    /// The layout for an image of `version`, whose picture's name the alias
    /// carries. Nothing else in it depends on the version.
    static func template(version: String) throws -> Data {
        let alias = AliasRecord.background(version: version)
        var records: [DSRecord] = [
            DSRecord(".", "bwsp", .blob(try browserWindowSettings())),
            DSRecord(".", "icvp", .blob(try iconViewSettings(backgroundAlias: alias))),
            DSRecord(".", "vSrn", .long(1)),
            DSRecord(".", "vstl", .type("icnv")),
            DSRecord(DiskImage.appName, "Iloc", .blob(location(DiskImage.appIcon))),
            DSRecord(DiskImage.applicationsName, "Iloc", .blob(location(DiskImage.applicationsIcon))),
        ]
        // Hidden items sit far to the right, so even with hidden files shown
        // they never land on the picture.
        let hidden = [DiskImage.backgroundFolder, ".DS_Store", ".fseventsd", ".Trashes"]
        for (index, name) in hidden.enumerated() {
            records.append(DSRecord(name, "Iloc", .blob(location(CGPoint(x: 2560 + 50 * index, y: 170)))))
        }
        return try DSStoreFile(records: records).encoded()
    }

    private static func browserWindowSettings() throws -> Data {
        let frame = CGRect(
            x: windowOrigin.x, y: windowOrigin.y,
            width: DiskImage.content.width, height: DiskImage.content.height + titleBarHeight)
        let settings = NSMutableDictionary()
        settings["ContainerShowSidebar"] = false
        settings["PreviewPaneVisibility"] = false
        settings["ShowPathbar"] = false
        settings["ShowSidebar"] = false
        settings["ShowStatusBar"] = false
        settings["ShowTabView"] = false
        settings["ShowToolbar"] = false
        settings["SidebarWidth"] = 180
        settings["WindowBounds"] = NSStringFromRect(frame)
        return try PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0)
    }

    private static func iconViewSettings(backgroundAlias: Data) throws -> Data {
        let ground = 118.0 / 255
        let settings = NSMutableDictionary()
        settings["arrangeBy"] = "none"
        // Used only if the picture is ever switched off: the same ground.
        settings["backgroundColorBlue"] = ground
        settings["backgroundColorGreen"] = ground
        settings["backgroundColorRed"] = ground
        settings["backgroundImageAlias"] = backgroundAlias
        settings["backgroundType"] = 2
        settings["gridOffsetX"] = 0.0
        settings["gridOffsetY"] = 0.0
        settings["gridSpacing"] = 100.0
        settings["iconSize"] = DiskImage.iconSize
        settings["labelOnBottom"] = true
        settings["scrollPositionX"] = 0.0
        settings["scrollPositionY"] = 0.0
        settings["showIconPreview"] = false
        settings["showItemInfo"] = false
        settings["textSize"] = DiskImage.labelSize
        settings["viewOptionsVersion"] = 1
        return try PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0)
    }

    /// An icon's centre, then Finder's fixed trailer.
    private static func location(_ point: CGPoint) -> Data {
        var bytes = BigEndian()
        bytes.u32(UInt32(point.x))
        bytes.u32(UInt32(point.y))
        bytes.u32(0xFFFF_FFFF)
        bytes.u32(0xFFFF_0000)
        return bytes.data
    }
}

/// A classic (version 2) alias record for the picture, the form Finder stores
/// in the icon view's backgroundImageAlias.
enum AliasRecord {
    static func background(version: String) -> Data {
        let volume = DiskImage.volumeName
        let folder = DiskImage.backgroundFolder
        let file = DiskImage.backgroundName(version: version)
        let date = macTime(FinderLayout.fixedDate)

        var record = BigEndian()
        record.bytes(Data(count: 4))  // application information
        record.u16(0)  // the record's length, filled in below
        record.u16(2)  // version
        record.u16(0)  // a file
        record.pascal(volume, field: 28)
        record.u32(date)  // the volume's creation date
        record.ascii("H+")
        record.u16(0)  // a fixed disk
        record.u32(DiskImage.backgroundFolderID)
        record.pascal(file, field: 64)
        record.u32(DiskImage.backgroundFileID)
        record.u32(date)  // the file's creation date
        record.bytes(Data(count: 8))  // creator and type codes
        record.u16(0xFFFF)  // levels from the alias to the shared folder: none
        record.u16(0xFFFF)  // levels from there to the target: none
        record.u32(0)  // volume attributes
        record.bytes(Data(count: 2))  // file system ID
        record.bytes(Data(count: 10))  // reserved

        record.tag(0, Data(folder.utf8))  // the parent folder's name
        record.tag(16, highResolution(date))  // the volume's creation date
        record.tag(17, highResolution(date))  // the file's creation date
        var folderIDs = BigEndian()
        folderIDs.u32(DiskImage.backgroundFolderID)
        record.tag(1, folderIDs.data)  // the folder IDs on the path
        record.tag(2, Data("\(volume):\(folder):\u{0}\(file)".utf8))  // the Carbon path
        record.tag(14, unicodeName(file))
        record.tag(15, unicodeName(volume))
        record.tag(18, Data("/\(folder)/\(file)".utf8))  // the path on the volume
        record.tag(19, Data("/Volumes/\(volume)".utf8))  // where the volume mounts
        record.u16(0xFFFF)  // the end
        record.u16(0)

        var data = record.data
        let length = UInt16(data.count)
        data[4] = UInt8(length >> 8)
        data[5] = UInt8(length & 0xFF)
        return data
    }

    /// Seconds since 1 January 1904.
    private static func macTime(_ date: Date) -> UInt32 { UInt32(date.timeIntervalSince1970 + 2_082_844_800) }

    private static func highResolution(_ seconds: UInt32) -> Data {
        var bytes = BigEndian()
        bytes.u64(UInt64(seconds) << 16)
        return bytes.data
    }

    private static func unicodeName(_ name: String) -> Data {
        let units = Array(name.utf16)
        var bytes = BigEndian()
        bytes.u16(UInt16(units.count))
        for unit in units { bytes.u16(unit) }
        return bytes.data
    }
}

struct DSRecord {
    enum Value {
        case blob(Data)
        case long(UInt32)
        case type(String)
    }

    let name: String
    let code: String
    let value: Value

    init(_ name: String, _ code: String, _ value: Value) {
        self.name = name
        self.code = code
        self.value = value
    }

    /// Finder sorts by name, ignoring case, then by code.
    static func precedes(_ lhs: DSRecord, _ rhs: DSRecord) -> Bool {
        let left = lhs.name.lowercased()
        let right = rhs.name.lowercased()
        return left == right ? lhs.code < rhs.code : left < right
    }

    func write(into bytes: inout BigEndian) {
        let units = Array(name.utf16)
        bytes.u32(UInt32(units.count))
        for unit in units { bytes.u16(unit) }
        bytes.ascii(code)
        switch value {
        case .blob(let data):
            bytes.ascii("blob")
            bytes.u32(UInt32(data.count))
            bytes.bytes(data)
        case .long(let number):
            bytes.ascii("long")
            bytes.u32(number)
        case .type(let fourCC):
            bytes.ascii("type")
            bytes.ascii(fourCC)
        }
    }
}

/// The file around the records: a 4-byte prefix, then a buddy-allocated space
/// of 8192 bytes holding the allocator's header (0–32), the B-tree's DSDB
/// superblock (32–64), the allocator's own block (2048–4096) and one leaf
/// node (4096–8192), as a fresh store holding one page of records is laid out.
struct DSStoreFile {
    let records: [DSRecord]

    private static let pageSize = 4096
    private static let superblockAddress: UInt32 = 32
    private static let allocatorAddress: UInt32 = 2048
    private static let leafAddress: UInt32 = 4096

    func encoded() throws -> Data {
        let sorted = records.sorted(by: DSRecord.precedes)
        var leaf = BigEndian()
        leaf.u32(0)  // no right-hand child: a leaf
        leaf.u32(UInt32(sorted.count))
        for record in sorted { record.write(into: &leaf) }
        guard leaf.data.count <= Self.pageSize else { throw LayoutError("The layout no longer fits one page.") }

        // Blocks: 0 is the allocator's own, 1 the superblock, 2 the leaf. An
        // address carries its block's size as log2 in the low five bits.
        let blockAddresses: [UInt32] = [Self.allocatorAddress | 11, Self.superblockAddress | 5, Self.leafAddress | 12]
        var allocator = BigEndian()
        allocator.u32(UInt32(blockAddresses.count))
        allocator.u32(0)
        for address in blockAddresses { allocator.u32(address) }
        allocator.bytes(Data(count: 4 * (256 - blockAddresses.count)))
        allocator.u32(1)  // one directory entry
        allocator.u8(4)
        allocator.ascii("DSDB")
        allocator.u32(1)
        // Free lists by size: what is left of the 2^31 space once the header,
        // the superblock, the allocator's block and the leaf are taken.
        let taken: Set<Int> = [5, 11, 12]
        for power in 0..<32 {
            if power >= 5, power <= 30, !taken.contains(power) {
                allocator.u32(1)
                allocator.u32(UInt32(1) << UInt32(power))
            } else {
                allocator.u32(0)
            }
        }
        guard allocator.data.count <= 2048 else { throw LayoutError("The allocator's block overflowed.") }

        var superblock = BigEndian()
        superblock.u32(2)  // the root node is the leaf
        superblock.u32(0)  // no internal levels
        superblock.u32(UInt32(sorted.count))
        superblock.u32(1)  // one node
        superblock.u32(UInt32(Self.pageSize))

        var header = BigEndian()
        header.ascii("Bud1")
        header.u32(Self.allocatorAddress)
        header.u32(2048)
        header.u32(Self.allocatorAddress)
        // Opaque to readers; this is what a new store carries.
        for word: UInt32 in [0x0000_100C, 0x0000_0087, 0x0000_200B, 0] { header.u32(word) }

        var space = Data(count: 8192)
        space.replaceSubrange(0..<header.data.count, with: header.data)
        space.replace(at: Int(Self.superblockAddress), with: superblock.data)
        space.replace(at: Int(Self.allocatorAddress), with: allocator.data)
        space.replace(at: Int(Self.leafAddress), with: leaf.data)

        var file = BigEndian()
        file.u32(1)
        file.bytes(space)
        return file.data
    }
}

// MARK: - Helpers

struct LayoutError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct BigEndian {
    private(set) var data = Data()

    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func bytes(_ other: Data) { data.append(other) }
    mutating func ascii(_ text: String) { data.append(contentsOf: Array(text.utf8)) }

    /// A length byte, then the text, zero-padded to `field` bytes.
    mutating func pascal(_ text: String, field: Int) {
        let utf8 = Array(text.utf8.prefix(field - 1))
        data.append(UInt8(utf8.count))
        data.append(contentsOf: utf8)
        data.append(contentsOf: [UInt8](repeating: 0, count: field - 1 - utf8.count))
    }

    /// An alias tag: its number, its length, the value and a pad to an even
    /// length.
    mutating func tag(_ number: UInt16, _ value: Data) {
        u16(number)
        u16(UInt16(value.count))
        data.append(value)
        if value.count % 2 == 1 { data.append(0) }
    }
}

extension Data {
    fileprivate mutating func replace(at offset: Int, with bytes: Data) {
        replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
}

// MARK: - Command line

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let appRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let arguments = Array(CommandLine.arguments.dropFirst())

do {
    let version: String
    let directory: URL
    switch arguments.first {
    case nil:
        let infoURL = appRoot.appending(path: "Resources/Info.plist")
        guard
            let info = NSDictionary(contentsOf: infoURL),
            let committedVersion = info["CFBundleShortVersionString"] as? String
        else { throw LayoutError("Could not read the version in \(infoURL.path).") }
        version = committedVersion
        directory = appRoot.appending(path: "Resources/DMG")
    case "picture" where arguments.count == 3:
        version = arguments[1]
        directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
    default:
        throw LayoutError("Usage: render-dmg-layout.swift [picture <version> <directory>]")
    }
    // The version names the picture's file, so it must be the plain three
    // numbers package-app.sh and create-dmg.sh accept.
    let components = version.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3, components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
    else { throw LayoutError("The version must contain three numeric components: \(version)") }
    try Picture.write(version: version, into: directory)
    try FinderLayout.template(version: version).write(to: directory.appending(path: "DS_Store.template"))
    print("Wrote \(directory.path) for \(version)")
} catch {
    FileHandle.standardError.write(Data("render-dmg-layout: \(error)\n".utf8))
    exit(1)
}
