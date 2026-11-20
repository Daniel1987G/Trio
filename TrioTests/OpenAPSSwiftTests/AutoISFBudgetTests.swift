import Foundation
import Testing
@testable import Trio

@Suite("autoISF insulin budget") struct AutoISFBudgetTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(
        minutesAgo: Double,
        rate: Decimal,
        plainRate: Decimal,
        smb: Decimal = 0,
        plainSMB: Decimal = 0,
        minutes: Decimal = 30
    ) -> AutoISFBudget.Entry {
        AutoISFBudget.Entry(
            date: now.addingTimeInterval(-minutesAgo * 60),
            rate: rate,
            plainRate: plainRate,
            smb: smb,
            plainSMB: plainSMB,
            minutes: minutes
        )
    }

    private func dose(_ rate: Decimal, smb: Decimal = 0) -> AutoISFBudget.Dose {
        AutoISFBudget.Dose(rate: rate, minutes: 30, smb: smb)
    }

    @Test("budget is hours of the highest scheduled basal") func budget() {
        let profile = [
            BasalProfileEntry(start: "00:00:00", minutes: 0, rate: 0.8),
            BasalProfileEntry(start: "06:00:00", minutes: 360, rate: 1.2)
        ]
        #expect(AutoISFBudget.budget(basalProfile: profile, hours: 3) == 3.6)
    }

    @Test("temp differences count for the time they ran, SMBs at once") func tally() {
        let entries = [
            // +1 U/h for 10 minutes until the next loop
            entry(minutesAgo: 20, rate: 2, plainRate: 1),
            // +0.5 U SMB, then the same rate until now (10 minutes, no difference)
            entry(minutesAgo: 10, rate: 1, plainRate: 1, smb: 0.8, plainSMB: 0.3)
        ]
        let extra = AutoISFBudget.extraInsulin(entries, now: now)
        #expect(abs(NSDecimalNumber(decimal: extra - (Decimal(1) / 6 + 0.5)).doubleValue) < 0.0001)
    }

    @Test("a temp counts at most for its duration") func durationCap() {
        let entries = [entry(minutesAgo: 60, rate: 2, plainRate: 1, minutes: 30)]
        #expect(AutoISFBudget.extraInsulin(entries, now: now) == 0.5)
    }

    @Test("only the last 3 hours count") func window() {
        let entries = [
            entry(minutesAgo: 200, rate: 1, plainRate: 1, smb: 2, plainSMB: 0),
            entry(minutesAgo: 190, rate: 3, plainRate: 1, minutes: 30)
        ]
        // the SMB 200 min ago is out; the temp ran from 190 to 160 min ago, 20 minutes of it within the window
        let extra = AutoISFBudget.extraInsulin(entries, now: now)
        #expect(abs(NSDecimalNumber(decimal: extra - Decimal(2) * 20 / 60).doubleValue) < 0.0001)
    }

    @Test("autoISF doses while under the budget") func allowed() {
        let ledger = AutoISFBudget.Ledger(entries: [entry(minutesAgo: 30, rate: 1, plainRate: 1, smb: 1, plainSMB: 0)])
        let verdict = AutoISFBudget.verdict(ledger: ledger, now: now, budget: 3, autoISF: dose(2), plain: dose(1))
        // 1 U past + 0.5 U this temp
        #expect(verdict == .allowed(used: 1.5))
    }

    @Test("over the budget the loop doses as oref") func exceeded() {
        let ledger = AutoISFBudget.Ledger(entries: [entry(minutesAgo: 30, rate: 1, plainRate: 1, smb: 2.8, plainSMB: 0)])
        let verdict = AutoISFBudget.verdict(ledger: ledger, now: now, budget: 3, autoISF: dose(1, smb: 0.5), plain: dose(1))
        #expect(verdict == .exceeded(used: 3.3))
    }

    @Test("less insulin than oref is always allowed and credited down to minus the budget") func lessIsAllowed() {
        let ledger = AutoISFBudget.Ledger(entries: [entry(minutesAgo: 30, rate: 1, plainRate: 1, smb: 0, plainSMB: 5)])
        // past is -5, floored at -3; this loop +1 U SMB → -2
        let verdict = AutoISFBudget.verdict(ledger: ledger, now: now, budget: 3, autoISF: dose(1, smb: 1), plain: dose(1))
        #expect(verdict == .allowed(used: -2))
        let less = AutoISFBudget.verdict(ledger: AutoISFBudget.Ledger(), now: now, budget: 0.1, autoISF: dose(0), plain: dose(1))
        #expect(less == .allowed(used: -0.5))
    }

    @Test("an unreadable ledger blocks extra insulin for 3 hours") func resetLedger() {
        let ledger = AutoISFBudget.Ledger(reset: now.addingTimeInterval(-60 * 60))
        let verdict = AutoISFBudget.verdict(ledger: ledger, now: now, budget: 3, autoISF: dose(1, smb: 0.1), plain: dose(1))
        if case .exceeded = verdict {} else { Issue.record("expected exceeded, got \(verdict)") }
        let later = AutoISFBudget.verdict(
            ledger: ledger,
            now: now.addingTimeInterval(3 * 60 * 60),
            budget: 3,
            autoISF: dose(1, smb: 0.1),
            plain: dose(1)
        )
        #expect(later == .allowed(used: 0.1))
    }

    @Test("recording trims old entries and clears the reset after the window") func recording() {
        var ledger = AutoISFBudget.Ledger(reset: now.addingTimeInterval(-4 * 60 * 60))
        ledger.entries = [entry(minutesAgo: 300, rate: 1, plainRate: 1), entry(minutesAgo: 60, rate: 1, plainRate: 1)]
        let recorded = AutoISFBudget.recording(entry(minutesAgo: 0, rate: 2, plainRate: 1), in: ledger)
        #expect(recorded.entries.count == 2)
        #expect(recorded.reset == nil)
    }

    @Test("dose of a determination") func doseOfDetermination() {
        let temp = TempBasal(duration: 20, rate: 1.5, temp: .absolute, timestamp: now)
        let noTemp = TempBasal(duration: 0, rate: 0, temp: .absolute, timestamp: now)
        var determination = Determination(
            id: nil, reason: "", units: 0.3, insulinReq: nil, eventualBG: nil, sensitivityRatio: nil,
            rate: 2, duration: 30, iob: nil, cob: nil, predictions: nil, deliverAt: now, carbsReq: nil,
            temp: nil, bg: nil, reservoir: nil, isf: nil, timestamp: nil, tdd: nil, current_target: nil,
            minDelta: nil, expectedDelta: nil, minGuardBG: nil, minPredBG: nil, threshold: nil,
            carbRatio: nil, received: nil
        )
        #expect(AutoISFBudget.Dose(determination, currentTemp: temp, scheduledBasal: 1) == dose(2, smb: 0.3))
        determination.rate = nil
        determination.duration = nil
        #expect(
            AutoISFBudget.Dose(determination, currentTemp: temp, scheduledBasal: 1) ==
                AutoISFBudget.Dose(rate: 1.5, minutes: 20, smb: 0.3)
        )
        #expect(AutoISFBudget.Dose(determination, currentTemp: noTemp, scheduledBasal: 1) == dose(1, smb: 0.3))
    }

    @Test("tag goes into the first part of the reason") func tagging() {
        let reason = "Autosens ratio: 1, ISF: 50→40; Eventual BG 120"
        #expect(
            AutoISFBudget.tagging(reason, with: "aISF budget 1/3U") ==
                "Autosens ratio: 1, ISF: 50→40, aISF budget 1/3U; Eventual BG 120"
        )
        #expect(AutoISFBudget.tag(used: 3.26, budget: 3, exceeded: true) == "aISF budget 3.3/3U: oref")
    }
}
