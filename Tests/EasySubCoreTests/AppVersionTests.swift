import Testing
@testable import EasySubCore

@Suite("App version comparison")
struct AppVersionTests {
    @Test func acceptsReleaseTags() {
        #expect(AppVersion("v1.2.3")?.description == "1.2.3")
        #expect(AppVersion("  V2.0  ")?.description == "2.0")
        #expect(AppVersion("1.2.3+45")?.description == "1.2.3")
    }

    @Test func comparesNumericComponents() {
        #expect(AppVersion("1.10.0")! > AppVersion("1.9.9")!)
        #expect(AppVersion("1.0")! == AppVersion("1.0.0")!)
        #expect(AppVersion("2.0")! > AppVersion("1.99.99")!)
    }

    @Test func comparesPrereleases() {
        #expect(AppVersion("1.0.0")! > AppVersion("1.0.0-rc.1")!)
        #expect(AppVersion("1.0.0-rc.2")! > AppVersion("1.0.0-rc.1")!)
        #expect(AppVersion("1.0.0-beta.11")! > AppVersion("1.0.0-beta.2")!)
    }

    @Test func rejectsInvalidVersions() {
        #expect(AppVersion("") == nil)
        #expect(AppVersion("release-1.0") == nil)
        #expect(AppVersion("1..0") == nil)
    }
}
