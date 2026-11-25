import XCTest

/// Launch smoke test: Spectra must open its main window (sidebar + library)
/// within 10 s. Run with a host app from Xcode (`Product > Test`), the app
/// bundle being produced by `./make-app.sh release`.
final class SpectraUITests: XCTestCase {

    func testLaunchOpensMainWindow() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10),
                      "Spectra should open its main window on launch")
    }
}
