import XCTest
@testable import ThreeOneOSFive

final class AutoDisablePatchPolicyTests: XCTestCase {
    func testDefaultsAreEnabledAndEightSeconds() {
        XCTAssertTrue(AutoDisablePatchPolicy.defaultEnabled)
        XCTAssertEqual(AutoDisablePatchPolicy.defaultTimeoutSeconds, 8, accuracy: 0.000_001)
    }

    func testDeadlineIsExactlyEightSecondsByDefault() {
        let start = Date(timeIntervalSince1970: 1_000)
        let deadline = AutoDisablePatchPolicy.deadline(from: start)
        XCTAssertEqual(deadline.timeIntervalSince(start), 8, accuracy: 0.000_001)
    }

    func testCustomDeadlineRemainsInjectableForSchedulerTests() {
        let start = Date(timeIntervalSince1970: 1_000)
        let deadline = AutoDisablePatchPolicy.deadline(from: start, timeoutSeconds: 3)
        XCTAssertEqual(deadline.timeIntervalSince(start), 3, accuracy: 0.000_001)
    }
}
