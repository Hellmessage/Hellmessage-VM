// HVMInstallTests/PartialMetaTests.swift
// _PartialMeta 是 file-private (internal access? 实际上 fileprivate scope), 所以这里测试
// IPSWFetcher 路径上接触得到的状态 — cache path / partial path 的命名约定.

import XCTest
@testable import HVMInstall

final class IPSWFetcherPathTests: XCTestCase {

    func testCachedPathFromBuild() {
        let url = IPSWFetcher.cachedPath(buildVersion: "24A335")
        XCTAssertEqual(url.lastPathComponent, "24A335.ipsw")
    }

    func testPartialPathFromBuild() {
        let url = IPSWFetcher.partialPath(buildVersion: "24A335")
        XCTAssertEqual(url.lastPathComponent, "24A335.ipsw.partial")
    }

    func testPartialMetaPathFromBuild() {
        let url = IPSWFetcher.partialMetaPath(buildVersion: "24A335")
        XCTAssertEqual(url.lastPathComponent, "24A335.ipsw.partial.meta")
    }

    func testIsCachedFalseForUnknownBuild() {
        XCTAssertFalse(IPSWFetcher.isCached(buildVersion: "no-such-build-\(UUID().uuidString)"))
    }
}

final class IPSWCatalogEntryCodableTests: XCTestCase {

    func testRoundTrip() throws {
        let entry = IPSWCatalogEntry(
            buildVersion: "24A335",
            osVersion: "15.0",
            url: URL(string: "https://example.com/UniversalMac_15.0_24A335_Restore.ipsw")!,
            minCPU: 4,
            minMemoryMiB: 8192,
            postingDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(IPSWCatalogEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
    }

    func testOptionalFieldsCanBeNil() throws {
        let entry = IPSWCatalogEntry(
            buildVersion: "x",
            osVersion: "?",
            url: URL(string: "https://e.com/x.ipsw")!
        )
        XCTAssertNil(entry.minCPU)
        XCTAssertNil(entry.minMemoryMiB)
        XCTAssertNil(entry.postingDate)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(IPSWCatalogEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
    }
}
