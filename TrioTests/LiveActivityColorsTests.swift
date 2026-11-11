import Foundation
import SwiftUI
import Testing

@testable import Trio

@Suite("Live Activity colours") struct LiveActivityColorsTests {
    @Test("Hex colours survive a round trip") func hexRoundTrip() {
        for hex in ["#FF0000", "#00FF00", "#1E90FF", "#12345680"] {
            let color = Color(liveActivityHex: hex)
            #expect(color != nil, "\(hex) did not parse")
            #expect(color?.liveActivityHex == hex)
        }
    }

    @Test("Invalid hex strings are ignored") func invalidHex() {
        for hex in ["", "#12", "red", "#GGGGGG"] {
            #expect(Color(liveActivityHex: hex) == nil, "\(hex) parsed")
        }
    }

    @Test("Elements without an own colour keep the built-in look") func defaults() {
        var colors = LiveActivityColors.default
        #expect(colors.isDefault)
        #expect(colors.color(.iob) == nil)
        colors[.iob] = "#FF0000"
        #expect(!colors.isDefault)
        #expect(colors.color(.iob) != nil)
        #expect(colors.color(.cob) == nil)
    }

    @Test("Settings without the colours key still decode") func legacySettings() throws {
        let data = try JSONEncoder().encode(TrioSettings())
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "liveActivityColors")
        let decoded = try JSONDecoder().decode(TrioSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.liveActivityColors == .default)

        var settings = TrioSettings()
        settings.liveActivityColors.background = "#000000"
        let roundTrip = try JSONDecoder().decode(TrioSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip.liveActivityColors.background == "#000000")
    }
}
