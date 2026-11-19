import AppKit

/// Stet's drawn artwork: app icon, book (document) icon, and the title page used as a
/// thumbnail for books without a cover. Shared by scripts/make-icons.sh and the Quick Look
/// thumbnail extension. Draws into the current NSGraphicsContext (y axis up).
///
/// The motif is the proofreader's *stet* mark: a row of dots under a word, meaning
/// "let it stand – restore what was crossed out".
enum StetArtwork {
    static let paperTop = NSColor(srgbRed: 0.992, green: 0.984, blue: 0.965, alpha: 1)
    static let paperBottom = NSColor(srgbRed: 0.930, green: 0.898, blue: 0.832, alpha: 1)
    static let ink = NSColor(srgbRed: 0.165, green: 0.145, blue: 0.122, alpha: 1)
    static let mutedInk = NSColor(srgbRed: 0.42, green: 0.39, blue: 0.35, alpha: 1)
    static let accent = NSColor(srgbRed: 0.66, green: 0.32, blue: 0.16, alpha: 1)

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

    /// Four dots under a span, centered on `centerX`.
    static func drawDots(centerX: CGFloat, y: CGFloat, span: CGFloat, radius: CGFloat, color: NSColor = accent) {
        color.setFill()
        let count = 4
        let step = span / CGFloat(count - 1)
        for i in 0..<count {
            let x = centerX - span / 2 + CGFloat(i) * step
            NSBezierPath(ovalIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)).fill()
        }
    }

    /// The word "stet" with the dots beneath it; `baseline` is the text baseline.
    static func drawStetMark(centerX: CGFloat, baseline: CGFloat, fontSize: CGFloat) {
        let text = NSAttributedString(string: "stet", attributes: [.font: serif(fontSize), .foregroundColor: ink])
        let size = text.size()
        let font = serif(fontSize)
        text.draw(at: CGPoint(x: centerX - size.width / 2, y: baseline + font.descender))
        drawDots(centerX: centerX, y: baseline - fontSize * 0.2, span: size.width * 0.78, radius: fontSize * 0.042)
    }

    // MARK: - App icon

    static func drawAppIcon(in rect: CGRect) {
        let s = rect.width
        let body = rect.insetBy(dx: s * 0.0977, dy: s * 0.0977)
        let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.2237, yRadius: body.width * 0.2237)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = CGSize(width: 0, height: -s * 0.01)
        shadow.shadowBlurRadius = s * 0.03
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.set()
        paperBottom.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        fillPaper(path)
        NSColor.black.withAlphaComponent(0.08).setStroke()
        path.lineWidth = max(1, s * 0.002)
        path.stroke()

        drawStetMark(centerX: body.midX, baseline: body.midY - s * 0.045, fontSize: s * 0.30)
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

        drawStetMark(centerX: page.midX, baseline: page.midY - s * 0.02, fontSize: s * 0.17)
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

        drawDots(centerX: rect.midX, y: rect.minY + h * 0.12, span: w * 0.14, radius: w * 0.012)
    }
}
