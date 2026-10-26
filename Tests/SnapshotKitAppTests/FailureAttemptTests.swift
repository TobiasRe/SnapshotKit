import SnapshotKitCore
import Testing
@testable import SnapshotKitUI

/// A failing test's images, from several devices, test cases, runs or assertions, are told apart by
/// only what varies, and runs are numbered per device.
struct FailureAttemptTests {
    func image(_ device: String?, run: Int, index: Int = 0, arguments: [String]? = nil) -> SnapshotFailureImages {
        SnapshotFailureImages(testIdentifier: "CheckoutTests/pay()", repetition: run, index: index,
                              device: device, deviceID: device, arguments: arguments)
    }

    @Test func runsOfOneDeviceAreNumberedAmongAllRuns() {
        let attempts = FailuresTab.attempts(of: [image("iPhone SE", run: 3), image("iPhone SE", run: 2)], runsPerDevice: 5)
        #expect(attempts.map(\.title) == ["Run 2 of 5", "Run 3 of 5"])
    }

    /// A 5× check on two simulators is "Run 3 of 5" on each, not "Run 3 of 10".
    @Test func twoDevicesNameTheDeviceAndCountRunsPerDevice() {
        let images = [image("iPhone SE", run: 3), image("iPad", run: 1), image("iPhone SE", run: 1)]
        #expect(FailuresTab.attempts(of: images, runsPerDevice: 5).map(\.title)
                == ["iPad · Run 1 of 5", "iPhone SE · Run 1 of 5", "iPhone SE · Run 3 of 5"])
    }

    @Test func testCasesAndAssertionsAreNamedWhenTheyVary() {
        let images = [image("iPhone SE", run: 1, arguments: ["\"dark\""]), image("iPhone SE", run: 1, arguments: ["\"light\""]),
                      image("iPhone SE", run: 1, index: 1, arguments: ["\"light\""])]
        #expect(FailuresTab.attempts(of: images, runsPerDevice: 1).map(\.title)
                == ["\"dark\" · Snapshot 1", "\"light\" · Snapshot 1", "\"light\" · Snapshot 2"])
    }

    @Test func oneImageNeedsNoName() {
        #expect(FailuresTab.attempts(of: [image("iPhone SE", run: 1)], runsPerDevice: 1).map(\.title) == [""])
    }
}
