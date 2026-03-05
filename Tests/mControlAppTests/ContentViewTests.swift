import Testing
@testable import mControlApp

@Suite("ContentView defaults")
struct ContentViewTests {
    @MainActor
    @Test("dashboard custom duration uses the stored preference")
    func dashboardCustomDurationUsesStoredPreference() {
        #expect(ContentView.dashboardCustomDurationMinutes(135) == 135)
    }

    @MainActor
    @Test("dashboard custom duration clamps out of range values")
    func dashboardCustomDurationClampsOutOfRangeValues() {
        #expect(ContentView.dashboardCustomDurationMinutes(0) == CustomDurationDefaults.minimumMinutes)
        #expect(
            ContentView.dashboardCustomDurationMinutes(20_000) == CustomDurationDefaults.maximumMinutes
        )
    }
}
