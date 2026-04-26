// HVMQemuTests/QemuKeyMapTests.swift
// 字符 / 组合键 → qkey 映射的纯函数测试.

import XCTest
@testable import HVMQemu

final class QemuKeyMapTests: XCTestCase {

    // MARK: - parseCombo

    func testCtrlCParsed() throws {
        XCTAssertEqual(try QemuKeyMap.parseCombo("ctrl+c"), ["ctrl", "c"])
    }

    func testCmdAliasMappedToMetaL() throws {
        XCTAssertEqual(try QemuKeyMap.parseCombo("cmd+space"), ["meta_l", "spc"])
        XCTAssertEqual(try QemuKeyMap.parseCombo("win+l"),     ["meta_l", "l"])
        XCTAssertEqual(try QemuKeyMap.parseCombo("super+a"),   ["meta_l", "a"])
    }

    func testThreeKeyCombo() throws {
        XCTAssertEqual(try QemuKeyMap.parseCombo("ctrl+alt+delete"),
                       ["ctrl", "alt", "delete"])
    }

    func testFunctionKeys() throws {
        XCTAssertEqual(try QemuKeyMap.parseCombo("f1"),  ["f1"])
        XCTAssertEqual(try QemuKeyMap.parseCombo("F12"), ["f12"])
        XCTAssertThrowsError(try QemuKeyMap.parseCombo("f25"))   // 超出 f1-f24
    }

    func testReturnAndArrows() throws {
        XCTAssertEqual(try QemuKeyMap.parseCombo("return"), ["ret"])
        XCTAssertEqual(try QemuKeyMap.parseCombo("up"),     ["up"])
        XCTAssertEqual(try QemuKeyMap.parseCombo("pgup"),   ["pgup"])
    }

    func testUnknownKeyThrows() {
        XCTAssertThrowsError(try QemuKeyMap.parseCombo("ctrl+菜单")) { error in
            guard case QemuKeyMap.MapError.unknownKey = error else {
                return XCTFail("期望 unknownKey, 实际 \(error)")
            }
        }
    }

    // MARK: - tokenizeText

    func testTokenizeLowercaseText() throws {
        let tokens = try QemuKeyMap.tokenizeText("hi")
        XCTAssertEqual(tokens, [["h"], ["i"]])
    }

    func testTokenizeUppercaseAddsShift() throws {
        let tokens = try QemuKeyMap.tokenizeText("Hi")
        XCTAssertEqual(tokens, [["shift", "h"], ["i"]])
    }

    func testTokenizeMixedAndPunctuation() throws {
        // "Hi!" → H i !
        // ! 是 shift+1
        let tokens = try QemuKeyMap.tokenizeText("Hi!")
        XCTAssertEqual(tokens, [["shift", "h"], ["i"], ["shift", "1"]])
    }

    func testTokenizeSpaceAndDigits() throws {
        let tokens = try QemuKeyMap.tokenizeText("a 1")
        XCTAssertEqual(tokens, [["a"], ["spc"], ["1"]])
    }

    func testTokenizeNewlineAsReturn() throws {
        let tokens = try QemuKeyMap.tokenizeText("a\nb")
        XCTAssertEqual(tokens, [["a"], ["ret"], ["b"]])
    }

    func testTokenizeRejectsNonASCII() {
        XCTAssertThrowsError(try QemuKeyMap.tokenizeText("hello 中"))
    }
}
