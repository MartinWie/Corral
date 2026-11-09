import Foundation
import Testing
@testable import CorralCore

struct NotificationSettingsTests {
    @Test func defaultsAreAllOnWithSoundForWhatWaitsOnYou() {
        let n = NotificationSettings()
        #expect(NotificationKind.allCases.allSatisfy { n[$0].on })
        #expect(n[.permission].sound && n[.question].sound)
        #expect(!n[.finished].sound && !n[.failed].sound && !n[.command].sound)
        #expect(n.whileActive && n.showDetails)
    }

    @Test func changesRoundTripAndDefaultsStayImplicit() throws {
        var n = NotificationSettings()
        n[.finished].on = false
        n[.permission].sound = false
        n.whileActive = false
        let data = try JSONEncoder().encode(n)
        let back = try JSONDecoder().decode(NotificationSettings.self, from: data)
        #expect(back == n)
        #expect(!back[.finished].on && !back[.permission].sound && !back.whileActive)
        // Setting a rule back to its default leaves no entry: equal to a fresh value again.
        var reset = back
        reset[.finished].on = true
        reset[.permission].sound = true
        reset.whileActive = true
        #expect(reset == NotificationSettings())
    }

    @Test func oldOrDamagedFilesLoadWithDefaults() throws {
        let empty = try JSONDecoder().decode(NotificationSettings.self, from: Data("{}".utf8))
        #expect(empty == NotificationSettings())
        let damaged = try JSONDecoder().decode(NotificationSettings.self,
                                               from: Data(#"{"rules":{"permission":7},"whileActive":"yes"}"#.utf8))
        #expect(damaged == NotificationSettings())
        // One bad rule keeps the others; explicit defaults read like missing ones.
        let mixed = try JSONDecoder().decode(NotificationSettings.self, from: Data(
            #"{"rules":{"permission":{"on":"x"},"finished":{"on":false,"sound":false},"question":{"on":true,"sound":true}},"showDetails":false}"#.utf8))
        #expect(mixed[.permission] == NotificationSettings.defaultRule(.permission) && !mixed[.finished].on && !mixed.showDetails)
        var expected = NotificationSettings()
        expected[.finished].on = false
        expected.showDetails = false
        #expect(mixed == expected)
        let rules = try JSONDecoder().decode(NotificationSettings.self, from: Data(#"{"rules":[1,2]}"#.utf8))
        #expect(rules == NotificationSettings())
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"keepAwake":true,"notifications":3}"#.utf8))
        #expect(settings.keepAwake && settings.notifications == NotificationSettings())
        #expect(AppSettings(notifications: { var n = NotificationSettings(); n.whileActive = false; return n }()) != AppSettings())
    }

    @Test func kindsFromANewerVersionSurvive() throws {
        let json = #"{"rules":{"future":{"on":false,"sound":true},"question":{"on":false,"sound":true}},"whileActive":true}"#
        var n = try JSONDecoder().decode(NotificationSettings.self, from: Data(json.utf8))
        #expect(!n[.question].on)
        n[.failed].sound = true
        let again = try JSONSerialization.jsonObject(with: JSONEncoder().encode(n)) as? [String: Any]
        let rules = try #require(again?["rules"] as? [String: Any])
        #expect(rules["future"] != nil && rules["failed"] != nil)
    }
}
