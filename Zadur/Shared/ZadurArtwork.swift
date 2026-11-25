import AppKit
import CoreText

/// Zadur's drawn artwork: the book (document) icon, and the title page used as a thumbnail for
/// books without a cover. Shared by scripts/make-icons.sh and the Quick Look thumbnail extension.
/// Draws into the current NSGraphicsContext (y axis up).
///
/// The motif is the app icon's (Zadur-Icon-Kit): a lowercase serif z, a period, and an oxblood
/// insertion cursor, ready to keep writing.
enum ZadurArtwork {
    static let paperTop = NSColor(srgbRed: 0.988, green: 0.949, blue: 0.898, alpha: 1)
    static let paperBottom = NSColor(srgbRed: 0.957, green: 0.882, blue: 0.788, alpha: 1)
    static let ink = NSColor(srgbRed: 0.125, green: 0.105, blue: 0.085, alpha: 1)
    static let mutedInk = NSColor(srgbRed: 0.42, green: 0.39, blue: 0.35, alpha: 1)
    static let accent = NSColor(srgbRed: 0.655, green: 0.055, blue: 0.055, alpha: 1)

    static func serif(_ size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        var descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor.withDesign(.serif)
            ?? NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        if italic { descriptor = descriptor.withSymbolicTraits(.italic) }
        return NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size)
    }

    // MARK: - Building blocks

    static func fillPaper(_ path: NSBezierPath) {
        NSGradient(starting: paperTop, ending: paperBottom)?.draw(in: path, angle: -90)
    }

    /// The insertion cursor alone.
    static func drawCursor(centerX: CGFloat, bottom: CGFloat, height: CGFloat) {
        accent.setFill()
        let width = height * 0.0875
        NSBezierPath(rect: CGRect(x: centerX - width / 2, y: bottom, width: width, height: height)).fill()
    }

    /// "z." and the cursor, in the app icon's proportions; `xHeight` is the height of the z.
    static func drawMark(centerX: CGFloat, baseline: CGFloat, xHeight: CGFloat) {
        let font = serif(100, weight: .bold)
        var character: UniChar = 0x7A
        var glyph = CGGlyph()
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), let outline = CTFontCreatePathForGlyph(font, glyph, nil),
              let context = NSGraphicsContext.current?.cgContext
        else { return }
        let box = outline.boundingBoxOfPath
        let scale = xHeight / box.height
        let zWidth = box.width * scale
        let gap = xHeight * 0.11, dot = xHeight * 0.22, bar = xHeight * 0.117
        var x = centerX - (zWidth + gap + dot + gap + bar) / 2

        context.saveGState()
        context.translateBy(x: x - box.minX * scale, y: baseline - box.minY * scale)
        context.scaleBy(x: scale, y: scale)
        context.addPath(outline)
        context.setFillColor(ink.cgColor)
        context.fillPath()
        context.restoreGState()
        x += zWidth + gap
        ink.setFill()
        NSBezierPath(ovalIn: CGRect(x: x, y: baseline, width: dot, height: dot)).fill()
        x += dot + gap
        drawCursor(centerX: x + bar / 2, bottom: baseline, height: xHeight * 1.34)
    }

    // MARK: - Book (document) icon

    static func drawDocumentIcon(in rect: CGRect) {
        let s = rect.width
        let page = CGRect(x: rect.midX - s * 0.33, y: rect.midY - s * 0.43, width: s * 0.66, height: s * 0.86)
        let fold = s * 0.15
        let outline = NSBezierPath()
        outline.move(to: CGPoint(x: page.minX, y: page.minY))
        outline.line(to: CGPoint(x: page.maxX, y: page.minY))
        outline.line(to: CGPoint(x: page.maxX, y: page.maxY - fold))
        outline.line(to: CGPoint(x: page.maxX - fold, y: page.maxY))
        outline.line(to: CGPoint(x: page.minX, y: page.maxY))
        outline.close()

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = CGSize(width: 0, height: -s * 0.008)
        shadow.shadowBlurRadius = s * 0.02
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.set()
        paperBottom.setFill()
        outline.fill()
        NSGraphicsContext.restoreGraphicsState()

        fillPaper(outline)
        NSColor.black.withAlphaComponent(0.12).setStroke()
        outline.lineWidth = max(1, s * 0.003)
        outline.stroke()

        let corner = NSBezierPath()
        corner.move(to: CGPoint(x: page.maxX - fold, y: page.maxY))
        corner.line(to: CGPoint(x: page.maxX - fold, y: page.maxY - fold))
        corner.line(to: CGPoint(x: page.maxX, y: page.maxY - fold))
        corner.close()
        paperBottom.blended(withFraction: 0.25, of: .black)?.withAlphaComponent(0.35).setFill()
        corner.fill()

        // Faint lines of manuscript text above and below the mark.
        NSColor.black.withAlphaComponent(0.12).setFill()
        let lineHeight = s * 0.014
        let left = page.minX + s * 0.08
        let widths: [CGFloat] = [0.40, 0.48, 0.30, 0.48, 0.44, 0.24]
        for (i, width) in widths.enumerated() {
            let y = i < 3 ? page.maxY - s * (0.20 + 0.055 * CGFloat(i)) : page.minY + s * (0.20 - 0.055 * CGFloat(i - 3))
            NSBezierPath(roundedRect: CGRect(x: left, y: y, width: s * width, height: lineHeight), xRadius: lineHeight / 2, yRadius: lineHeight / 2).fill()
        }

        drawMark(centerX: page.midX, baseline: page.midY - s * 0.085, xHeight: s * 0.15)
    }

    // MARK: - Title page (thumbnail for books without a cover)

    static func drawTitlePage(title: String, author: String?, in rect: CGRect) {
        let w = rect.width, h = rect.height
        let page = NSBezierPath(rect: rect)
        fillPaper(page)
        NSColor.black.withAlphaComponent(0.1).setStroke()
        page.lineWidth = max(1, w * 0.004)
        page.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.hyphenationFactor = 0.6

        let textWidth = w * 0.76
        var fontSize = w * 0.095
        var titleText = NSAttributedString(string: title, attributes: [.font: serif(fontSize, weight: .medium), .foregroundColor: ink, .paragraphStyle: paragraph])
        var titleBox = titleText.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin)
        while titleBox.height > h * 0.38, fontSize > w * 0.04 {
            fontSize *= 0.9
            titleText = NSAttributedString(string: title, attributes: [.font: serif(fontSize, weight: .medium), .foregroundColor: ink, .paragraphStyle: paragraph])
            titleBox = titleText.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin)
        }
        let titleTop = rect.minY + h * 0.70
        titleText.draw(with: CGRect(x: rect.midX - textWidth / 2, y: titleTop - titleBox.height, width: textWidth, height: titleBox.height),
                       options: .usesLineFragmentOrigin)

        if let author, !author.isEmpty {
            let authorText = NSAttributedString(string: author, attributes: [.font: serif(w * 0.05, italic: true), .foregroundColor: mutedInk, .paragraphStyle: paragraph])
            let box = authorText.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin)
            authorText.draw(with: CGRect(x: rect.midX - textWidth / 2, y: titleTop - titleBox.height - w * 0.06 - box.height, width: textWidth, height: box.height),
                            options: .usesLineFragmentOrigin)
        }

        drawCursor(centerX: rect.midX, bottom: rect.minY + h * 0.09, height: w * 0.11)
    }
}
