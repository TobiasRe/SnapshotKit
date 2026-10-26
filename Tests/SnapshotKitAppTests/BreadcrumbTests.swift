import Testing
@testable import SnapshotKitUI

/// Section headers name the test target only when the list has several, like the library's modules.
struct BreadcrumbTests {
    @Test func aSuiteReadsAsItsPath() {
        #expect(Breadcrumb.of(identifier: "AppSnapshotTests/CheckoutViewTests") == "AppSnapshotTests › CheckoutViewTests")
        #expect(Breadcrumb.of(identifier: "AppSnapshotTests/CheckoutViewTests", showingBundle: false) == "CheckoutViewTests")
        // A nested suite keeps its outer suite; only the bundle goes.
        #expect(Breadcrumb.of(identifier: "AppSnapshotTests/Checkout/Buttons", showingBundle: false) == "Checkout › Buttons")
        #expect(Breadcrumb.of(identifier: "CheckoutViewTests", showingBundle: false) == "CheckoutViewTests")
    }

    @Test func severalBundlesAreToldApart() {
        #expect(!Breadcrumb.severalBundles(["AppSnapshotTests/A", "AppSnapshotTests/B"]))
        #expect(Breadcrumb.severalBundles(["AppSnapshotTests/A", "DesignSystemTests/B"]))
        #expect(!Breadcrumb.severalBundles([String]()))
    }
}
