import CoreGraphics
import XCTest
@testable import Burrow

final class TreemapLayoutTests: XCTestCase {
    func testTileAreaIsProportionalToEntrySize() {
        let entries = [entry("large", size: 75), entry("small", size: 25)]
        let tiles = TreemapLayout.tiles(for: entries, in: CGRect(x: 0, y: 0, width: 200, height: 100))

        XCTAssertEqual(tiles.count, 2)
        XCTAssertEqual(tiles[0].rect.width * tiles[0].rect.height, 15_000, accuracy: 0.001)
        XCTAssertEqual(tiles[1].rect.width * tiles[1].rect.height, 5_000, accuracy: 0.001)
    }

    func testTilesFillBoundsWithoutLosingEntries() {
        let entries = (1...40).map { entry("item-\($0)", size: Int64($0)) }
        let bounds = CGRect(x: 11, y: 17, width: 731, height: 419)
        let tiles = TreemapLayout.tiles(for: entries, in: bounds)
        let tiledArea = tiles.reduce(CGFloat.zero) { $0 + $1.rect.width * $1.rect.height }

        XCTAssertEqual(tiles.count, entries.count)
        XCTAssertEqual(tiledArea, bounds.width * bounds.height, accuracy: 0.01)
        XCTAssertTrue(tiles.allSatisfy { bounds.contains($0.rect) })
    }

    func testZeroSizedEntriesAreNotRendered() {
        let tiles = TreemapLayout.tiles(
            for: [entry("empty", size: 0), entry("visible", size: 10)],
            in: CGRect(x: 0, y: 0, width: 100, height: 100)
        )

        XCTAssertEqual(tiles.map(\.entry.name), ["visible"])
    }

    private func entry(_ name: String, size: Int64) -> AnalyzeReport.Entry {
        AnalyzeReport.Entry(name: name, path: "/\(name)", size: size, isDirectory: true)
    }
}
