// HVMDisplayTests/OCRTextSearchTests.swift

import XCTest
@testable import HVMDisplay

final class OCRTextSearchTests: XCTestCase {

    private func item(_ text: String, x: Int = 0, y: Int = 0) -> OCREngine.TextItem {
        OCREngine.TextItem(x: x, y: y, width: 100, height: 20, text: text, confidence: 0.9)
    }

    func testFindCaseInsensitive() {
        let items = [item("Hello"), item("World")]
        let hit = OCRTextSearch.find(in: items, query: "hello")
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.item.text, "Hello")
    }

    func testFindReturnsFirstMatch() {
        let items = [item("apple", x: 10), item("Apple", x: 200)]
        let hit = OCRTextSearch.find(in: items, query: "apple")
        XCTAssertEqual(hit?.item.x, 10)
    }

    func testFindSubstring() {
        let items = [item("Submit Application")]
        let hit = OCRTextSearch.find(in: items, query: "submit")
        XCTAssertNotNil(hit)
    }

    func testNoMatchReturnsNil() {
        let items = [item("foo"), item("bar")]
        XCTAssertNil(OCRTextSearch.find(in: items, query: "qux"))
    }

    func testEmptyQueryReturnsNil() {
        let items = [item("hello")]
        XCTAssertNil(OCRTextSearch.find(in: items, query: ""))
    }

    func testEmptyItemsReturnsNil() {
        XCTAssertNil(OCRTextSearch.find(in: [], query: "x"))
    }
}
