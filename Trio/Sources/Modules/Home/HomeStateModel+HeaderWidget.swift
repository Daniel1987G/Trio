import Foundation
import SwiftUI

/// Hands the header's content to the header widget (home screen and CarPlay).
extension Home.StateModel {
    /// Collects a burst of changes (glucose, determination, IOB, pump) into one write.
    func scheduleHeaderWidgetUpdate() {
        headerWidgetTask?.cancel()
        headerWidgetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            HeaderWidgetStore.save(self.headerWidgetSnapshot())
        }
    }

    private func headerWidgetSnapshot() -> HeaderWidgetSnapshot {
        let last = latestTwoGlucoseValues.last
        let previous = latestTwoGlucoseValues.count >= 2 ? latestTwoGlucoseValues.first : nil
        let glucose = last.map { Int($0.glucose) }
        let delta: Int? = {
            guard let last, let previous else { return nil }
            return Int(last.glucose) - Int(previous.glucose)
        }()

        // in range the header uses the label colour, which the widget resolves itself (nil)
        let isOutOfRange = glucose.map { Decimal($0) <= lowGlucose || Decimal($0) >= highGlucose } ?? false
        let glucoseColor = last.flatMap { isOutOfRange ? $0 : nil }.map {
            CurrentGlucoseView.glucoseColor(
                for: $0.glucose,
                lowGlucose: lowGlucose,
                highGlucose: highGlucose,
                targetGlucose: currentGlucoseTarget,
                scheme: glucoseColorScheme
            )
        }
        let rangeColor: Color? = glucose.map {
            if Decimal($0) < lowGlucose { return .loopRed }
            if Decimal($0) > highGlucose { return .orange }
            return .loopGreen
        }

        let automationOn = dosingMode.automation != .off
        let hasEnacted = determinationsFromPersistence.first?.timestamp != nil
        let followsAge = automationOn && !manualTempBasal && hasEnacted
        let fixedLoopColor: Color? = followsAge ? nil : LoopView.ringColor(
            automation: dosingMode.automation,
            manualTempBasal: manualTempBasal,
            hasDeviceIssue: hasDeviceIssue,
            hasEnactedDetermination: hasEnacted,
            secondsSinceLastLoop: Date().timeIntervalSince(lastLoopDate)
        )

        let reservoirIsOver50 = reservoir == 0xDEAD_BEEF
        let battery = batteryFromPersistence.first
        let concentrationBadge: String? = (!pumpInsulinConcentration.isStandard || pumpInsulinConcentrationSyncPending)
            ? "U\(pumpInsulinConcentration.rawValue)" + (pumpInsulinConcentrationSyncPending ? "!" : "")
            : nil

        return HeaderWidgetSnapshot(
            glucose: glucose,
            glucoseDate: last?.date,
            delta: delta,
            trendSymbols: Self.trendSymbols(for: last?.directionEnum),
            units: units.rawValue,
            glucoseColorHex: glucoseColor.map(\.liveActivityHex),
            rangeColorHex: rangeColor.map(\.liveActivityHex),
            dosingModeName: dosingMode.displayName,
            lastLoopDate: lastLoopDate == .distantPast ? nil : lastLoopDate,
            loopColorFollowsAge: followsAge,
            fixedLoopColorHex: fixedLoopColor.map(\.liveActivityHex),
            loopColorHexes: [Color.loopGreen, Color.loopYellow, Color.loopRed].map(\.liveActivityHex),
            dynamicISFRatio: isDynamicISFEnabled ?
                enactedAndNonEnactedDeterminations.first?.sensitivityRatio?.doubleValue : nil,
            iob: NSDecimalNumber(decimal: currentIOB).doubleValue,
            cob: Int(enactedAndNonEnactedDeterminations.first?.cob ?? 0),
            eventualGlucose: enactedAndNonEnactedDeterminations.first?.eventualBG?.intValue,
            reservoir: reservoirIsOver50 ? nil : reservoir.map { NSDecimalNumber(decimal: $0).doubleValue },
            reservoirIsOver50: reservoirIsOver50,
            pumpExpiresAt: pumpExpiresAtDate,
            pumpBatteryPercent: (battery?.display == true) ? battery.map { Int($0.percent) } : nil,
            pumpMessage: pumpStatusHighlightMessage?.replacingOccurrences(of: "\n", with: " "),
            insulinConcentrationBadge: concentrationBadge,
            updatedAt: Date()
        )
    }

    private static func trendSymbols(for direction: BloodGlucose.Direction?) -> [String] {
        switch direction {
        case .doubleUp,
             .tripleUp: return ["arrow.up", "arrow.up"]
        case .singleUp: return ["arrow.up"]
        case .fortyFiveUp: return ["arrow.up.right"]
        case .flat: return ["arrow.right"]
        case .fortyFiveDown: return ["arrow.down.right"]
        case .singleDown: return ["arrow.down"]
        case .doubleDown,
             .tripleDown: return ["arrow.down", "arrow.down"]
        default: return []
        }
    }
}
