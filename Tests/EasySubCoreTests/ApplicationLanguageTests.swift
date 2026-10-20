import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import EasySubCore
#endif

@Test func applicationLanguagePreferences() throws {
    let domain = "EasySub.LanguageTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }

    #expect(ApplicationLanguage.current(in: defaults, domainName: domain) == .system)
    for language in [ApplicationLanguage.simplifiedChinese, .english] {
        language.save(in: defaults)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == [language.rawValue])
        #expect(ApplicationLanguage.current(in: defaults, domainName: domain) == language)
    }

    ApplicationLanguage.system.save(in: defaults)
    #expect(defaults.persistentDomain(forName: domain)?["AppleLanguages"] == nil)
    #expect(ApplicationLanguage.current(in: defaults, domainName: domain) == .system)
}
