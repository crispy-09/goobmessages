import XCTest
@testable import GMessagesMac

final class DockIconModeTests: XCTestCase {
    func testDockIconPolicy() {
        XCTAssertTrue(DockIconMode.always.showsDockIcon(hasOpenWindow: false))
        XCTAssertTrue(DockIconMode.always.showsDockIcon(hasOpenWindow: true))
        XCTAssertTrue(DockIconMode.whileOpen.showsDockIcon(hasOpenWindow: true))
        XCTAssertFalse(DockIconMode.whileOpen.showsDockIcon(hasOpenWindow: false))
        XCTAssertFalse(DockIconMode.never.showsDockIcon(hasOpenWindow: true))
    }

    func testUnknownStoredValueFallsBackToAlways() {
        XCTAssertNil(DockIconMode(rawValue: "bogus"))
        XCTAssertEqual(DockIconMode(rawValue: "whileOpen"), .whileOpen)
    }
}
