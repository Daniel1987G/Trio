import Charts
import Foundation
import SwiftUI

struct CarbView: ChartContent {
    let glucoseData: [GlucoseStored]
    let units: GlucoseUnits
    let carbData: [CarbEntryStored]
    let fpuData: [CarbEntryStored]
    let minValue: Decimal
    /// Extended boluses entered as carbs: one bar each instead of their single entries.
    var extendedPlans: [ExtendedCarbPlan] = []
    var now = Date()

    var body: some ChartContent {
        drawCarbs()
        drawFpus()
        drawExtendedPlans()
    }

    private var extendedPlanIDs: Set<UUID> { Set(extendedPlans.map(\.fpuID)) }

    /// Bar across the span of an extended bolus at the bottom of the chart: faint for the whole
    /// span, filled up to now, labelled with the grams and the duration, with a dashed link from
    /// the main bolus to its start. Overlapping plans are stacked in lanes, each lane one bar plus
    /// room for its label above the one below.
    private func drawExtendedPlans() -> some ChartContent {
        let thickness: Decimal = units == .mgdL ? 8 : Decimal(string: "0.45")!
        let laneStep: Decimal = units == .mgdL ? 22 : Decimal(string: "1.2")!
        let lanes = ExtendedCarbPlans.lanes(for: extendedPlans)
        return ForEach(extendedPlans, id: \.fpuID) { plan in
            let minutes = max(0, Int(plan.end.timeIntervalSince(plan.start) / 60))
            let laneY = minValue + Decimal(lanes[plan.fpuID] ?? 0) * laneStep
            RectangleMark(
                xStart: .value("Start", plan.start, unit: .second),
                xEnd: .value("End", plan.end, unit: .second),
                yStart: .value("Bottom", laneY - thickness / 2),
                yEnd: .value("Top", laneY + thickness / 2)
            )
            .foregroundStyle(Color.orange.opacity(0.3))
            .cornerRadius(4)
            .annotation(position: .top, alignment: .leading, spacing: 2) {
                Text(
                    String(
                        localized: "\(plan.grams) g · \(formatHrMin(minutes))",
                        comment: "Chart label of an extended bolus entered as carbs: grams and duration"
                    )
                )
                .font(.caption2)
                .foregroundStyle(Color.orange)
            }

            // dashed link from the main bolus (drawn above the glucose curve) to the start of the bar
            if let glucose = MainChartHelper.timeToNearestGlucose(
                glucoseValues: glucoseData,
                time: plan.createdAt.timeIntervalSince1970
            )?.glucose {
                let bolusY = (units == .mgdL ? Decimal(glucose) : Decimal(glucose).asMmolL) +
                    MainChartHelper.bolusOffset(units: units)
                LineMark(
                    x: .value("Time", plan.createdAt, unit: .second),
                    y: .value("Value", bolusY),
                    series: .value("Extended bolus link", plan.fpuID.uuidString)
                )
                .foregroundStyle(Color.orange.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                LineMark(
                    x: .value("Time", plan.start, unit: .second),
                    y: .value("Value", laneY),
                    series: .value("Extended bolus link", plan.fpuID.uuidString)
                )
                .foregroundStyle(Color.orange.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }

            if now > plan.start {
                RectangleMark(
                    xStart: .value("Start", plan.start, unit: .second),
                    xEnd: .value("Now", min(now, plan.end), unit: .second),
                    yStart: .value("Bottom", laneY - thickness / 2),
                    yEnd: .value("Top", laneY + thickness / 2)
                )
                .foregroundStyle(Color.orange.opacity(0.85))
                .cornerRadius(4)
            }
        }
    }

    private func drawCarbs() -> some ChartContent {
        ForEach(carbData) { carb in
            let carbAmount = carb.carbs
            let carbDate = carb.date ?? Date()

            if let glucose = MainChartHelper.timeToNearestGlucose(
                glucoseValues: glucoseData,
                time: carbDate.timeIntervalSince1970
            )?.glucose {
                let yPosition = (units == .mgdL ? Decimal(glucose) : Decimal(glucose).asMmolL) - MainChartHelper
                    .bolusOffset(units: units)
                let size = min(
                    MainChartHelper.Config.carbsSize + CGFloat(carbAmount) * MainChartHelper.Config.carbsScale,
                    MainChartHelper.Config.maxCarbSize
                )

                PointMark(
                    x: .value("Time", carbDate, unit: .second),
                    y: .value("Value", yPosition)
                )
                .symbol {
                    Image(systemName: "arrowtriangle.down.fill").font(.system(size: size)).foregroundStyle(Color.orange)
                        .rotationEffect(.degrees(180))
                }

                PointMark(
                    x: .value("Time", carbDate, unit: .second),
                    y: .value("Value", yPosition)
                )
                .symbolSize(0)
                .annotation(position: .bottom) {
                    Text(Formatter.integerFormatter.string(from: carbAmount as NSNumber)!).font(.caption2)
                        .foregroundStyle(Color.primary)
                }
            }
        }
    }

    private func drawFpus() -> some ChartContent {
        let planIDs = extendedPlanIDs
        let singleEntries = fpuData.filter { entry in
            guard let fpuID = entry.fpuID else { return true }
            return !planIDs.contains(fpuID)
        }
        return ForEach(singleEntries, id: \.id) { fpu in
            let fpuAmount = fpu.carbs
            let size = (MainChartHelper.Config.fpuSize + CGFloat(fpuAmount) * MainChartHelper.Config.carbsScale) * 1.8
            let yPosition = minValue // value is parsed to mmol/L when passed into struct based on user settings

            PointMark(
                x: .value("Time", fpu.date ?? Date(), unit: .second),
                y: .value("Value", yPosition)
            )
            .symbolSize(size)
            .foregroundStyle(Color.brown)
        }
    }
}
