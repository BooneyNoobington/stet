import Foundation
import XCTest
@testable import ZadurCore

/// The find bar's plain search: case only matters when replacing.
final class TextSearchTests: XCTestCase {
    private func found(_ query: String, in text: String, caseSensitive: Bool = false) -> [String] {
        TextSearch.ranges(of: query, in: text, caseSensitive: caseSensitive).map { (text as NSString).substring(with: $0) }
    }

    func testFindingIgnoresCase() {
        XCTAssertEqual(found("mara", in: "Mara sah MARA und mara."), ["Mara", "MARA", "mara"])
        XCTAssertEqual(found("Ü", in: "Über die Brücke"), ["Ü", "ü"])
    }

    func testAccentsAndUmlautsCount() {
        XCTAssertEqual(found("Bar", in: "Die Bär-Bar"), ["Bar"])
        XCTAssertEqual(found("bär", in: "Die Bär-Bar"), ["Bär"])
        // A decomposed umlaut (as some Macs write it) is the same letter.
        XCTAssertEqual(found("Grüße", in: "Viele Gru\u{0308}ße").count, 1)
    }

    func testReplacingCountsCase() {
        XCTAssertEqual(found("Mara", in: "mara Mara MARA", caseSensitive: true), ["Mara"])
        let result = TextSearch.replacingAll("Mara", with: "Lena", in: "Mara und mara und Maras Hut")
        XCTAssertEqual(result.text, "Lena und mara und Lenas Hut")
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(TextSearch.replacingAll("x", with: "y", in: "abc").count, 0)
        // A replacement that contains the search text doesn't loop.
        XCTAssertEqual(TextSearch.replacingAll("Mara", with: "Mara Kessler", in: "Mara, Mara").text, "Mara Kessler, Mara Kessler")
    }

    func testRangesAreUTF16AndDontOverlap() {
        let text = "🌊 Welle 🌊 Welle"
        let ranges = TextSearch.ranges(of: "welle", in: text, caseSensitive: false)
        XCTAssertEqual(ranges.map(\.location), [3, 12])  // 🌊 is two UTF-16 units
        XCTAssertEqual(TextSearch.ranges(of: "aa", in: "aaaaa", caseSensitive: false).count, 2)
        XCTAssertEqual(TextSearch.ranges(of: "", in: "abc", caseSensitive: false).count, 0)
        XCTAssertEqual(TextSearch.ranges(of: "abc", in: "", caseSensitive: false).count, 0)
    }
}
