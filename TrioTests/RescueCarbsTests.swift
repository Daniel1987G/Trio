import Foundation
import Testing
@testable import Trio

@Suite("Rescue Carbs", .serialized) struct RescueCarbsTests {
    private static func withDefaults(_ body: () -> Void) {
        let suite = "RescueCarbsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let previous = RescueCarbSettings.defaults
        RescueCarbSettings.defaults = defaults
        body()
        RescueCarbSettings.defaults = previous
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("Defaults: 15 g, 140 mg/dL for 60 min") func defaults() {
        Self.withDefaults {
            #expect(RescueCarbSettings.grams == 15)
            #expect(RescueCarbSettings.tempTargetEnabled)
            #expect(RescueCarbSettings.tempTarget == 140)
            #expect(RescueCarbSettings.duration == 60)
        }
    }

    @Test("Stored values are kept within their ranges") func clamping() {
        Self.withDefaults {
            RescueCarbSettings.grams = 500
            #expect(RescueCarbSettings.grams == 60)
            RescueCarbSettings.defaults.set(1, forKey: RescueCarbSettings.tempTargetKey)
            #expect(RescueCarbSettings.tempTarget == 100)
            RescueCarbSettings.duration = 30
            #expect(RescueCarbSettings.duration == 30)
            RescueCarbSettings.tempTargetEnabled = false
            #expect(!RescueCarbSettings.tempTargetEnabled)
        }
    }

    @Test("A higher or equal active temp target keeps running") func keepActive() {
        #expect(RescueCarbs.keepsActiveTempTarget(activeTarget: 160, rescueTarget: 140))
        #expect(RescueCarbs.keepsActiveTempTarget(activeTarget: 140, rescueTarget: 140))
        #expect(!RescueCarbs.keepsActiveTempTarget(activeTarget: 100, rescueTarget: 140))
        #expect(!RescueCarbs.keepsActiveTempTarget(activeTarget: nil, rescueTarget: 140))
        #expect(!RescueCarbs.keepsActiveTempTarget(activeTarget: 0, rescueTarget: 140))
    }

    @Test("Log keeps the newest entries") func log() {
        let base = Date(timeIntervalSince1970: 1_793_000_000)
        var log: [RescueCarbEntry] = []
        for index in 0 ..< 60 {
            log = RescueCarbs.appending(RescueCarbEntry(date: base.addingTimeInterval(Double(index)), grams: 15), to: log)
        }
        #expect(log.count == RescueCarbs.maxLogEntries)
        #expect(log.last?.date == base.addingTimeInterval(59))
    }

    @Test("Recent entry within 2 hours") func recent() {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let log = [
            RescueCarbEntry(date: now.addingTimeInterval(-3 * 3600), grams: 20),
            RescueCarbEntry(date: now.addingTimeInterval(-20 * 60), grams: 15)
        ]
        #expect(RescueCarbs.recent(in: log, now: now)?.grams == 15)
        #expect(RescueCarbs.recent(in: [log[0]], now: now) == nil)
    }

    @Test("Rescue settings are part of settings backups") func backupKeys() {
        for key in RescueCarbSettings.backupKeys {
            #expect(SettingsBackup.extraKeys.contains(key))
        }
    }
}
