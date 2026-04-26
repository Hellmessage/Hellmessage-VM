// HVMDisplayTests/BootPhaseClassifierTests.swift
// 纯函数 OCR items + guestOS → 启动阶段分类.

import XCTest
@testable import HVMDisplay
import HVMBundle

final class BootPhaseClassifierTests: XCTestCase {

    private func item(_ text: String) -> OCREngine.TextItem {
        OCREngine.TextItem(x: 0, y: 0, width: 100, height: 20, text: text, confidence: 0.9)
    }

    func testEmptyItemsIsBootLogo() {
        let cls = BootPhaseClassifier.classify(items: [], guestOS: .linux)
        XCTAssertEqual(cls.phase, "boot-logo")
        XCTAssertEqual(cls.confidence, 0.6, accuracy: 1e-6)
    }

    func testTtyLoginPromptDetected() {
        let cls = BootPhaseClassifier.classify(
            items: [item("ubuntu login:")], guestOS: .linux
        )
        XCTAssertEqual(cls.phase, "ready-tty")
        XCTAssertGreaterThan(cls.confidence, 0.8)
    }

    func testLocalhostLoginDetected() {
        let cls = BootPhaseClassifier.classify(
            items: [item("localhost login: ")], guestOS: .linux
        )
        XCTAssertEqual(cls.phase, "ready-tty")
    }

    func testLinuxGuiKeywordDetected() {
        let cls = BootPhaseClassifier.classify(
            items: [item("Username"), item("Password")], guestOS: .linux
        )
        XCTAssertEqual(cls.phase, "ready-gui")
        XCTAssertEqual(cls.confidence, 0.8, accuracy: 1e-6)
    }

    func testMacOSGuiKeywordDetected() {
        let cls = BootPhaseClassifier.classify(
            items: [item("Sign in"), item("Other...")], guestOS: .macOS
        )
        XCTAssertEqual(cls.phase, "ready-gui")
    }

    func testWindowsGuiKeywordDetected() {
        let cls = BootPhaseClassifier.classify(
            items: [item("Administrator"), item("Sign in")], guestOS: .windows
        )
        XCTAssertEqual(cls.phase, "ready-gui")
    }

    func testChineseLoginKeywordDetected() {
        let cls = BootPhaseClassifier.classify(
            items: [item("用户名"), item("密码")], guestOS: .linux
        )
        XCTAssertEqual(cls.phase, "ready-gui")
    }

    func testUnrelatedTextIsUnknown() {
        let cls = BootPhaseClassifier.classify(
            items: [item("Installing packages..."), item("Step 5 of 8")],
            guestOS: .linux
        )
        XCTAssertEqual(cls.phase, "unknown")
        XCTAssertEqual(cls.confidence, 0.4, accuracy: 1e-6)
    }

    func testTtyTakesPriorityOverGui() {
        // 既有 tty 又有 GUI 关键字 → tty 优先 (置信度更高)
        let cls = BootPhaseClassifier.classify(
            items: [item("login:"), item("Username")], guestOS: .linux
        )
        XCTAssertEqual(cls.phase, "ready-tty")
    }
}
