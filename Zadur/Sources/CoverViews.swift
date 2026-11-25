import AppKit
import ImageIO
import ZadurCore
import SwiftUI

// MARK: - Setting the cover

extension BookSession {
    func chooseCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Ein Bild im Hochformat, am besten etwa 1600 × 2400 Pixel. Es wird die erste Seite des PDF-Buchs, das Cover des E-Books und das Symbol des Buchs im Finder."
        panel.prompt = "Als Titelbild verwenden"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setCover(from: url)
    }

    func setCover(from url: URL) {
        changeStructure { try book.setCover(from: url) }
        coverRevision += 1
    }

    func removeCover() {
        changeStructure { try book.removeCover() }
        coverRevision += 1
    }
}

// MARK: - The row in the inspector

/// The cover in the inspector: a small picture to click (or drop an image on), and buttons.
struct CoverControl: View {
    @ObservedObject var session: BookSession
    @State private var picture: NSImage?
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Button(picture == nil ? "Wählen …" : "Ändern …") { session.chooseCover() }
                    .controlSize(.small)
                if picture != nil {
                    Button("Entfernen") { session.removeCover() }
                        .controlSize(.small)
                }
            }
            Button { session.chooseCover() } label: {
                ZStack {
                    if let picture {
                        Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "photo").font(.title3).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 40, height: 60)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isTargeted ? 2 : 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(picture == nil ? "Titelbild wählen" : "Titelbild ändern")
        }
        .help("Erste Seite des PDF-Buchs, Cover des E-Books, Symbol im Finder. Ein Bild hierher ziehen oder wählen.")
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            session.setCover(from: url)
            return true
        } isTargeted: { isTargeted = $0 }
        .task(id: "\(session.manifest.cover ?? "")#\(session.coverRevision)") {
            picture = Self.thumbnail(session.book.coverURL)
        }
    }

    /// A small version for the inspector (the cover itself may be thousands of pixels).
    static func thumbnail(_ url: URL?) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
        ]
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}
