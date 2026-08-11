import Carbon
import Foundation
import Testing
@testable import MacPilot

struct InputSourceTests {
    @Test func browserDomainSuffixMatchesOnlyARealSubdomain() throws {
        let rule = InputSourceBrowserRule(
            browserBundleIdentifier: "com.google.Chrome",
            type: .domainSuffix,
            value: "example.com",
            inputSourceIdentifier: "com.example.input"
        )

        #expect(rule.matches(url: try #require(URL(string: "https://editor.example.com/file")), browserBundleIdentifier: "com.google.Chrome"))
        #expect(!rule.matches(url: try #require(URL(string: "https://notexample.com/file")), browserBundleIdentifier: "com.google.Chrome"))
        #expect(!rule.matches(url: try #require(URL(string: "https://editor.example.com/file")), browserBundleIdentifier: "com.apple.Safari"))
    }

    @Test func browserExactAndRegexRulesValidateInput() throws {
        let exact = InputSourceBrowserRule(
            type: .domain,
            value: "github.com",
            inputSourceIdentifier: "english"
        )
        let regex = InputSourceBrowserRule(
            type: .urlRegex,
            value: #"/pull/\d+"#,
            inputSourceIdentifier: "cjk"
        )

        #expect(exact.matches(url: try #require(URL(string: "https://github.com")), browserBundleIdentifier: nil))
        #expect(!exact.matches(url: try #require(URL(string: "https://gist.github.com")), browserBundleIdentifier: nil))
        #expect(regex.matches(url: try #require(URL(string: "https://github.com/acme/project/pull/42")), browserBundleIdentifier: nil))
        #expect(!regex.matches(url: try #require(URL(string: "https://github.com/acme/project/issues/42")), browserBundleIdentifier: nil))
    }

    @Test func browserRuleTakesPrecedenceOverAppAndDefaultRules() throws {
        var settings = InputSourceSettings()
        settings.defaultInputSourceIdentifier = "system-default"
        settings.appRules = [InputSourceAppRule(
            appName: "Chrome",
            bundleIdentifier: "com.google.Chrome",
            inputSourceIdentifier: "app-source"
        )]
        settings.browserRules = [InputSourceBrowserRule(
            browserBundleIdentifier: "com.google.Chrome",
            value: "github.com",
            inputSourceIdentifier: "website-source"
        )]

        let website = try #require(URL(string: "https://github.com/acme/project"))
        #expect(InputSourceRuleEngine.effectiveInputSourceIdentifier(
            bundleIdentifier: "com.google.Chrome",
            browserURL: website,
            settings: settings
        ) == "website-source")
        #expect(InputSourceRuleEngine.effectiveInputSourceIdentifier(
            bundleIdentifier: "com.google.Chrome",
            browserURL: nil,
            settings: settings
        ) == "app-source")
        #expect(InputSourceRuleEngine.effectiveInputSourceIdentifier(
            bundleIdentifier: "com.apple.Safari",
            browserURL: nil,
            settings: settings
        ) == "system-default")
    }

    @Test func inputSourceSettingsDecodeWithSafeIndicatorBounds() throws {
        let data = Data(#"{"isEnabled":true,"indicatorDuration":99,"indicatorPosition":"screenCenter"}"#.utf8)
        let settings = try JSONDecoder().decode(InputSourceSettings.self, from: data)

        #expect(settings.isEnabled)
        #expect(settings.indicatorDuration == 5)
        #expect(settings.indicatorPosition == .screenCenter)
        #expect(settings.showIndicator)
        #expect(settings.globalShortcutEnabled)
    }

    @Test func inputSourcePersistentIdentifierIncludesInputMode() {
        let source = MacPilotInputSource(
            sourceID: "com.apple.inputmethod.SCIM",
            inputModeID: "com.apple.inputmethod.SCIM.Pinyin",
            name: "拼音",
            isCJKV: true
        )

        #expect(source.id == "com.apple.inputmethod.SCIM::com.apple.inputmethod.SCIM.Pinyin")
        #expect(source.isCJKV)
    }

    @Test func shortcutBindingRoundTripsThroughCodable() throws {
        let binding = InputSourceShortcutBinding(
            inputSourceIdentifier: "com.example.input",
            keyCode: UInt16(kVK_ANSI_1),
            modifiers: [.option, .command]
        )

        let decoded = try JSONDecoder().decode(
            InputSourceShortcutBinding.self,
            from: JSONEncoder().encode(binding)
        )

        #expect(decoded == binding)
        #expect(decoded.displayName == "⌥⌘1")
    }
}
