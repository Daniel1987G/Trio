import Charts
import Foundation
import SwiftUI

struct InsulinView: ChartContent {
    let glucoseData: [GlucoseStored]
    let insulinData: [PumpEventStored]
    let units: GlucoseUnits
    let bolusDisplayThreshold: BolusDisplayThreshold
    /// Delivered extended bolus portions; matching automatic boluses are drawn orange instead of as SMBs.
    var extendedPortions: [ExtendedBolusPortion] = []

    private func isExtendedPortion(_ insulin: PumpEventStored, amount: Decimal, date: Date) -> Bool {
        guard insulin.bolus?.isSMB == true, !extendedPortions.isEmpty else { return false }
        return ExtendedBolusPortions.isPortion(date: date, amount: amount, in: extendedPortions)
    }

    var body: some ChartContent {
        drawBoluses()
    }

    private func drawBoluses() -> some ChartContent {
        ForEach(insulinData) { insulin in
            let amount = insulin.bolus?.amount ?? 0 as NSDecimalNumber
            let bolusDate = insulin.timestamp ?? Date()

            if amount != 0, let glucose = MainChartHelper.timeToNearestGlucose(
                glucoseValues: glucoseData,
                time: bolusDate.timeIntervalSince1970
            )?.glucose {
                let yPosition = (units == .mgdL ? Decimal(glucose) : Decimal(glucose).asMmolL) + MainChartHelper
                    .bolusOffset(units: units)
                let size = (MainChartHelper.Config.bolusSize + CGFloat(truncating: amount) * MainChartHelper.Config.bolusScale)

                PointMark(
                    x: .value("Time", bolusDate, unit: .second),
                    y: .value("Value", yPosition)
                )
                .symbol {
                    Image(systemName: "arrowtriangle.down.fill").font(.system(size: size))
                        .foregroundStyle(
                            isExtendedPortion(insulin, amount: amount as Decimal, date: bolusDate) ? Color.orange : Color.insulin
                        )
                }

                PointMark(
                    x: .value("Time", bolusDate, unit: .second),
                    y: .value("Value", yPosition)
                )
                .symbolSize(0)
                .annotation(position: .top) {
                    if amount as Decimal >= bolusDisplayThreshold.rawValue {
                        Text(Formatter.bolusFormatter.string(from: amount) ?? "")
                            .font(.caption2)
                            .foregroundStyle(Color.primary)
                    }
                }
            }
        }
    }
}
