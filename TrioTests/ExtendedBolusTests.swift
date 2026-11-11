import Foundation
import Testing
@testable import Trio

@Suite("Extended Bolus") struct ExtendedBolusTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// 3 U over 1 h: 0.25 U per 5 min.
    private func plan(total: Decimal = 3, minutes: Double = 60, delivered: Decimal = 0) -> ExtendedBolus {
        ExtendedBolus(
            id: UUID(),
            startDate: start,
            duration: minutes * 60,
            totalUnits: total,
            immediateUnits: 2,
            deliveredUnits: delivered
        )
    }

    /// Floors to 0.05 U steps like a typical pump table.
    private func roundDown(_ units: Decimal) -> Decimal {
        var scaled = units * 20
        var floored = Decimal()
        NSDecimalRound(&floored, &scaled, 0, .down)
        return floored / 20
    }

    private func step(_ plan: ExtendedBolus, minutes: Double, glucose: Decimal? = 140, minPred: Decimal? = 110) -> ExtendedBolus
        .Step
    {
        plan.nextStep(
            at: start.addingTimeInterval(minutes * 60),
            roundDown: roundDown,
            glucose: glucose,
            minPredictedGlucose: minPred,
            threshold: 70
        )
    }

    @Test("Delivers an even share per cycle") func evenShare() {
        #expect(plan().unitsPerInterval == Decimal(string: "0.25")!)
        #expect(step(plan(), minutes: 5) == .deliver(Decimal(string: "0.25")!))
        #expect(step(plan(delivered: Decimal(string: "0.25")!), minutes: 10) == .deliver(Decimal(string: "0.25")!))
    }

    @Test("Nothing before the first interval has passed") func nothingAtStart() {
        #expect(step(plan(), minutes: 0) == .wait)
        // 1 min in: 0.05 U due, exactly one pump step
        #expect(step(plan(), minutes: 1) == .deliver(Decimal(string: "0.05")!))
    }

    @Test("A delay holds back the first portion and shifts the end") func delayedStart() {
        var delayed = plan()
        delayed.delay = 30 * 60
        #expect(delayed.extendedStartDate == start.addingTimeInterval(30 * 60))
        #expect(delayed.endDate == start.addingTimeInterval(90 * 60))
        #expect(delayed.isWaitingForStart(at: start.addingTimeInterval(29 * 60)))
        #expect(step(delayed, minutes: 29) == .wait)
        #expect(step(delayed, minutes: 30) == .wait)
        #expect(step(delayed, minutes: 35) == .deliver(Decimal(string: "0.25")!))
        // a low during the delay still ends it
        #expect(step(delayed, minutes: 10, glucose: 60) == .finish(.lowGlucose))
        // not expired before the shifted end plus grace
        #expect(step(delayed, minutes: 100) != .finish(.expired))
    }

    @Test("Plans stored without a delay still decode") func decodesWithoutDelay() throws {
        let original = plan()
        let data = try JSONCoding.encoder.encode(original)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "delay")
        let decoded = try JSONCoding.decoder.decode(
            ExtendedBolus.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.delay == nil)
        #expect(decoded.extendedStartDate == start)
    }

    @Test("Extended units become whole grams with the carb ratio") func carbGrams() {
        #expect(ExtendedCarbEquivalents.grams(units: 2, carbRatio: 10) == 20)
        #expect(ExtendedCarbEquivalents.grams(units: Decimal(string: "1.25")!, carbRatio: 9) == 11)
        #expect(ExtendedCarbEquivalents.grams(units: 2, carbRatio: 0) == 0)
        #expect(ExtendedCarbEquivalents.grams(units: 0, carbRatio: 10) == 0)
    }

    @Test("Carb equivalents are spread every 30 min from the delayed start") func carbSchedule() {
        let begin = start.addingTimeInterval(30 * 60)
        let entries = ExtendedCarbEquivalents.schedule(grams: 25, start: begin, duration: 2 * 60 * 60)
        #expect(entries.map(\.grams) == [7, 6, 6, 6])
        #expect(entries.map(\.date) == (0 ..< 4).map { begin.addingTimeInterval(Double($0) * 30 * 60) })
        // never entries below 1 g, nothing for 0 g
        #expect(ExtendedCarbEquivalents.schedule(grams: 2, start: begin, duration: 4 * 60 * 60).map(\.grams) == [1, 1])
        #expect(ExtendedCarbEquivalents.schedule(grams: 0, start: begin, duration: 60 * 60).isEmpty)
    }

    @Test("The chart plan spans all entries plus one spacing") func carbPlan() {
        let begin = start.addingTimeInterval(30 * 60)
        let schedule = ExtendedCarbEquivalents.schedule(grams: 25, start: begin, duration: 2 * 60 * 60)
        let id = UUID()
        let plan = ExtendedCarbPlans.plan(fpuID: id, createdAt: start, schedule: schedule)
        #expect(plan?.start == begin)
        #expect(plan?.end == begin.addingTimeInterval(2 * 60 * 60))
        #expect(plan?.grams == 25)
        #expect(ExtendedCarbPlans.plan(fpuID: id, createdAt: start, schedule: []) == nil)

        let old = ExtendedCarbPlan(
            fpuID: UUID(),
            createdAt: start.addingTimeInterval(-11 * 24 * 60 * 60),
            start: start,
            end: start,
            grams: 5
        )
        #expect(ExtendedCarbPlans.appending(plan!, to: [old]) == [plan!])
    }

    private func carbPlan(from startMinutes: Double, to endMinutes: Double) -> ExtendedCarbPlan {
        ExtendedCarbPlan(
            fpuID: UUID(),
            createdAt: start.addingTimeInterval(startMinutes * 60 - 1800),
            start: start.addingTimeInterval(startMinutes * 60),
            end: start.addingTimeInterval(endMinutes * 60),
            grams: 20
        )
    }

    @Test("Overlapping extended carb plans get their own chart lane") func carbPlanLanes() {
        let first = carbPlan(from: 0, to: 120)
        let overlapping = carbPlan(from: 60, to: 180)
        let third = carbPlan(from: 90, to: 150)
        let fourth = carbPlan(from: 100, to: 200)
        let later = carbPlan(from: 150, to: 210)
        // shuffled input, lanes follow the start times
        let lanes = ExtendedCarbPlans.lanes(for: [later, third, first, fourth, overlapping])
        #expect(lanes[first.fpuID] == 0)
        #expect(lanes[overlapping.fpuID] == 1)
        #expect(lanes[third.fpuID] == 2)
        // no fourth lane: shares the lane that frees up first (the bottom one, ends at 120)
        #expect(lanes[fourth.fpuID] == 0)
        // all lanes still busy (with the 30 min gap): the one ending first, lane 2 (150)
        #expect(lanes[later.fpuID] == 2)

        // back to back with the gap: one lane
        let a = carbPlan(from: 0, to: 60)
        let b = carbPlan(from: 90, to: 150)
        let sequential = ExtendedCarbPlans.lanes(for: [a, b])
        #expect(sequential[a.fpuID] == 0)
        #expect(sequential[b.fpuID] == 0)
    }

    @Test("A gap is caught up by at most two intervals per cycle") func catchUpCapped() {
        // 30 min without delivery: 1.5 U behind, but only 0.5 U now
        #expect(step(plan(), minutes: 30) == .deliver(Decimal(string: "0.5")!))
    }

    @Test("Amounts below the pump step accumulate instead of being lost") func subStepAccumulates() {
        // 0.6 U over 1 h = 0.05 U per 5 min; after 2 min only 0.02 U are due
        let small = plan(total: Decimal(string: "0.6")!)
        #expect(step(small, minutes: 2) == .wait)
        #expect(step(small, minutes: 5) == .deliver(Decimal(string: "0.05")!))
    }

    @Test("Never more than what is left") func cappedByRemainder() {
        let almostDone = plan(delivered: Decimal(string: "2.9")!)
        #expect(step(almostDone, minutes: 60) == .deliver(Decimal(string: "0.1")!))
    }

    @Test("Low glucose ends it, a predicted low only pauses it") func lowGlucose() {
        #expect(step(plan(), minutes: 20, glucose: 68) == .finish(.lowGlucose))
        #expect(step(plan(), minutes: 20, glucose: 70) == .finish(.lowGlucose))
        if case .hold = step(plan(), minutes: 20, glucose: 120, minPred: 65) {} else {
            Issue.record("expected hold for predicted low")
        }
        // unknown glucose does not end it on its own
        #expect(step(plan(), minutes: 5, glucose: nil, minPred: nil) == .deliver(Decimal(string: "0.25")!))
    }

    @Test("Completes when everything is delivered or only a sub-step remainder is left") func completion() {
        #expect(step(plan(delivered: 3), minutes: 30) == .finish(.completed))
        let tiny = plan(delivered: Decimal(string: "2.98")!)
        #expect(step(tiny, minutes: 61) == .finish(.completed))
    }

    @Test("Undelivered insulin is dropped after the grace period") func expiry() {
        let behind = plan(delivered: 1)
        // within grace: keep catching up
        #expect(step(behind, minutes: 70) == .deliver(Decimal(string: "0.5")!))
        // after end + 15 min
        #expect(step(behind, minutes: 76) == .finish(.expired))
    }

    @Test("Ended plans do nothing") func ended() {
        let cancelled = plan().ending(.cancelledByUser, at: start)
        #expect(!cancelled.isActive)
        #expect(step(cancelled, minutes: 30) == .wait)
        // ending twice keeps the first reason
        #expect(cancelled.ending(.lowGlucose, at: start).endReason == .cancelledByUser)
    }

    @Test("Recording the last portion completes the plan") func recording() {
        let updated = plan(delivered: Decimal(string: "2.75")!)
            .recordingDelivery(of: Decimal(string: "0.25")!, at: start.addingTimeInterval(3600))
        #expect(updated.deliveredUnits == 3)
        #expect(updated.endReason == .completed)
        #expect(!updated.isActive)
    }

    @Test("Survives a round trip through storage") func codable() throws {
        let original = plan(delivered: 1).ending(.lowGlucose, at: start)
        let data = try JSONCoding.encoder.encode(original)
        let decoded = try JSONCoding.decoder.decode(ExtendedBolus.self, from: data)
        #expect(decoded == original)
    }

    @Test("Home panel shows running and early-stopped extended boluses") func panel() {
        let now = start.addingTimeInterval(20 * 60)
        let fresh = now.addingTimeInterval(-5 * 60)
        func resolve(_ bolus: ExtendedBolus?) -> MultiUsePanelState {
            MultiUsePanelState.resolve(
                notificationsDisabled: false,
                pumpTimeMismatch: false,
                lastGlucoseDate: fresh,
                maxIOB: 10,
                hasUnacknowledgedReleaseNotes: false,
                dosingMode: .closed,
                now: now,
                extendedBolus: bolus
            )
        }
        let running = plan()
        #expect(resolve(running) == .extendedBolus(running))
        let stoppedLow = plan().ending(.lowGlucose, at: now.addingTimeInterval(-60))
        #expect(resolve(stoppedLow) == .extendedBolus(stoppedLow))
        #expect(resolve(plan().ending(.completed, at: now)) == .stats)
        #expect(resolve(nil) == .stats)
    }
}

@Suite("Extended Bolus Portions") struct ExtendedBolusPortionTests {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)
    private let plan = UUID()

    @Test("A portion matches an automatic bolus of the same amount within 3 minutes") func matching() {
        let log = [ExtendedBolusPortion(date: now, units: Decimal(string: "0.3")!, planID: plan)]
        #expect(ExtendedBolusPortions.isPortion(date: now.addingTimeInterval(40), amount: Decimal(string: "0.3")!, in: log))
        // binary noise from the pump's Double amount
        #expect(ExtendedBolusPortions.isPortion(date: now, amount: Decimal(0.30000000000000004), in: log))
        #expect(!ExtendedBolusPortions.isPortion(date: now.addingTimeInterval(240), amount: Decimal(string: "0.3")!, in: log))
        #expect(!ExtendedBolusPortions.isPortion(date: now, amount: Decimal(string: "0.4")!, in: log))
        #expect(!ExtendedBolusPortions.isPortion(date: now, amount: 1, in: []))
    }

    @Test("Old portions are dropped") func retention() {
        let old = ExtendedBolusPortion(date: now.addingTimeInterval(-11 * 86400), units: 1, planID: plan)
        let recent = ExtendedBolusPortion(date: now.addingTimeInterval(-86400), units: 1, planID: plan)
        let log = ExtendedBolusPortions.appending(
            ExtendedBolusPortion(date: now, units: 1, planID: plan),
            to: [old, recent]
        )
        #expect(log.count == 2)
        #expect(!log.contains(old))
    }
}
