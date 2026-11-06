import Foundation

/// A bolus whose second part is spread evenly over a period ("extended", "square wave";
/// the immediate part is a normal bolus given when the extended bolus is started).
///
/// The extended part can start after a delay (time between the immediate bolus and the first
/// portion); the straight line then runs from `extendedStartDate` to `endDate`.
///
/// Trio delivers the extended part itself as small boluses on the loop cycle (about every
/// 5 minutes), so it works with every pump, is converted for the insulin concentration like any
/// other bolus, and shows up in IOB as soon as it is delivered. All amounts are actual units.
///
/// Missed cycles (phone out of range, stale glucose, pump busy) are caught up by at most one extra
/// interval per cycle; whatever cannot be delivered before `endDate + expiryGrace` is dropped.
/// Missing insulin is the fail-safe direction.
struct ExtendedBolus: JSON, Equatable {
    enum EndReason: String, Codable, Equatable {
        case completed
        case cancelledByUser
        case lowGlucose
        case expired
    }

    let id: UUID
    let startDate: Date
    /// Seconds over which `totalUnits` is spread.
    let duration: TimeInterval
    /// The extended part only, in actual insulin units.
    let totalUnits: Decimal
    /// The immediate part that was given when the bolus was started (informational).
    let immediateUnits: Decimal
    /// Seconds between the start (immediate bolus) and the first portion. Optional so plans stored
    /// before this field existed still decode; nil means no delay.
    var delay: TimeInterval?
    var deliveredUnits: Decimal = 0
    var lastDeliveryDate: Date?
    var endedAt: Date?
    var endReason: EndReason?

    /// Nominal spacing of the portions (the loop cycle).
    static let interval: TimeInterval = 5 * 60
    /// A cycle may deliver at most this many intervals' worth, so a gap is not caught up at once.
    static let maxIntervalsPerStep: Decimal = 2
    /// Undelivered insulin is dropped this long after `endDate`.
    static let expiryGrace: TimeInterval = 15 * 60

    static let minimumDuration: TimeInterval = 30 * 60
    static let maximumDuration: TimeInterval = 8 * 60 * 60
    static let maximumDelay: TimeInterval = 2 * 60 * 60

    /// When the first portion becomes due: `startDate` plus the delay.
    var extendedStartDate: Date { startDate.addingTimeInterval(max(0, delay ?? 0)) }
    var endDate: Date { extendedStartDate.addingTimeInterval(duration) }
    /// True while the delay before the first portion is still running.
    func isWaitingForStart(at date: Date) -> Bool { isActive && date < extendedStartDate }
    var isActive: Bool { endedAt == nil }
    var remainingUnits: Decimal { max(0, totalUnits - deliveredUnits) }

    /// Even share of one `interval`.
    var unitsPerInterval: Decimal {
        guard duration > 0 else { return totalUnits }
        return totalUnits * Decimal(Self.interval) / Decimal(duration)
    }

    /// How much should have been delivered by `date` on a straight line from the extended start to the end.
    func targetUnits(at date: Date) -> Decimal {
        guard date >= extendedStartDate else { return 0 }
        guard duration > 0 else { return totalUnits }
        let elapsed = min(max(date.timeIntervalSince(extendedStartDate), 0), duration)
        return totalUnits * Decimal(elapsed) / Decimal(duration)
    }

    /// Amount owed at `date` before pump rounding: behind schedule, capped per step and by what is left.
    func dueUnits(at date: Date) -> Decimal {
        let behind = max(0, targetUnits(at: date) - deliveredUnits)
        return min(behind, unitsPerInterval * Self.maxIntervalsPerStep, remainingUnits)
    }

    func isExpired(at date: Date) -> Bool {
        date >= endDate.addingTimeInterval(Self.expiryGrace)
    }

    // MARK: - Decision

    enum Step: Equatable {
        /// Deliver this many actual units now.
        case deliver(Decimal)
        /// Nothing due yet (or the due amount is below the pump's smallest step).
        case wait
        /// Hold this cycle; the reason is for the log.
        case hold(String)
        /// End the extended bolus.
        case finish(EndReason)
    }

    /// What to do on a loop cycle.
    ///
    /// - Parameters:
    ///   - roundDown: rounds an actual amount down to what the pump can deliver (concentration aware).
    ///   - glucose: current glucose in mg/dL, if known.
    ///   - minPredictedGlucose: lowest predicted glucose of the current determination, in mg/dL.
    ///   - threshold: the user's minimum safety threshold in mg/dL.
    func nextStep(
        at date: Date,
        roundDown: (Decimal) -> Decimal,
        glucose: Decimal?,
        minPredictedGlucose: Decimal?,
        threshold: Decimal
    ) -> Step {
        guard isActive else { return .wait }

        if remainingUnits <= 0 { return .finish(.completed) }

        // A low now ends the extended bolus; insulin given later cannot be taken back.
        if let glucose, glucose <= threshold { return .finish(.lowGlucose) }

        // A remainder smaller than the pump's smallest step cannot be delivered.
        let deliverableRemainder = roundDown(remainingUnits)
        if date >= endDate, deliverableRemainder <= 0 { return .finish(.completed) }
        if isExpired(at: date) { return .finish(deliverableRemainder <= 0 ? .completed : .expired) }

        // A predicted low pauses delivery; the loop is already lowering basal for it.
        if let minPredictedGlucose, minPredictedGlucose < threshold {
            return .hold("predicted glucose \(minPredictedGlucose) below threshold \(threshold)")
        }

        let amount = roundDown(dueUnits(at: date))
        return amount > 0 ? .deliver(amount) : .wait
    }

    // MARK: - Updates

    func recordingDelivery(of units: Decimal, at date: Date) -> ExtendedBolus {
        var copy = self
        copy.deliveredUnits += units
        copy.lastDeliveryDate = date
        if copy.remainingUnits <= 0 {
            copy.endedAt = date
            copy.endReason = .completed
        }
        return copy
    }

    func ending(_ reason: EndReason, at date: Date) -> ExtendedBolus {
        var copy = self
        copy.endedAt = copy.endedAt ?? date
        copy.endReason = copy.endReason ?? reason
        return copy
    }
}

/// The extended part of a bolus as delayed carb entries: the treatment screen gives the immediate
/// part as insulin and enters the extended units, converted with the carb ratio, as carb equivalents
/// spread over the duration after the delay. The loop then doses for each entry when it becomes due,
/// with all its safety limits, instead of Trio pushing insulin on a fixed schedule.
enum ExtendedCarbEquivalents {
    /// Spacing of the entries, as for Trio's fat-protein carb equivalents.
    static let spacing: TimeInterval = 30 * 60

    /// Whole grams for `units` actual insulin units at `carbRatio` g/U (0 without a valid ratio).
    static func grams(units: Decimal, carbRatio: Decimal) -> Int {
        guard units > 0, carbRatio > 0 else { return 0 }
        var value = units * carbRatio
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)
        return max(0, NSDecimalNumber(decimal: rounded).intValue)
    }

    /// `grams` split as evenly as possible (difference at most 1 g) into one entry per `spacing`
    /// of `duration`, the first at `start`. Never an entry below 1 g.
    static func schedule(grams: Int, start: Date, duration: TimeInterval) -> [(date: Date, grams: Int)] {
        guard grams > 0 else { return [] }
        let slots = max(1, Int(duration / spacing))
        let count = min(slots, grams)
        let base = grams / count
        let remainder = grams % count
        return (0 ..< count).map { index in
            (start.addingTimeInterval(Double(index) * spacing), base + (index < remainder ? 1 : 0))
        }
    }
}

/// The carb entries one extended bolus became, so chart and history can show them as one
/// extended bolus instead of fat-protein equivalents. Matched to the entries by `fpuID`.
struct ExtendedCarbPlan: JSON, Equatable {
    let fpuID: UUID
    let createdAt: Date
    /// Date of the first entry.
    let start: Date
    /// Date of the last entry plus one spacing, so the span covers the whole duration.
    let end: Date
    let grams: Int
}

enum ExtendedCarbPlans {
    /// Plans older than this are dropped (chart and history only show recent days).
    static let retention: TimeInterval = 10 * 24 * 60 * 60

    /// The plan for `schedule`, nil when there are no entries.
    static func plan(fpuID: UUID, createdAt: Date, schedule: [(date: Date, grams: Int)]) -> ExtendedCarbPlan? {
        guard let first = schedule.first, let last = schedule.last else { return nil }
        return ExtendedCarbPlan(
            fpuID: fpuID,
            createdAt: createdAt,
            start: first.date,
            end: last.date.addingTimeInterval(ExtendedCarbEquivalents.spacing),
            grams: schedule.reduce(0) { $0 + $1.grams }
        )
    }

    static func appending(_ plan: ExtendedCarbPlan, to log: [ExtendedCarbPlan]) -> [ExtendedCarbPlan] {
        let cutoff = plan.createdAt.addingTimeInterval(-retention)
        return log.filter { $0.createdAt >= cutoff && $0.fpuID != plan.fpuID } + [plan]
    }

    /// Chart lanes: overlapping plans get their own row so bars, fills and labels stay apart.
    static let maximumLanes = 3
    /// Free room after a bar before the next one may share its lane (keeps the labels apart).
    static let laneGap: TimeInterval = 30 * 60

    /// Lane per plan (0 = bottom), assigned by start time: the lowest lane that is free again,
    /// a new lane while fewer than `maximumLanes` exist, else the lane that frees up first.
    static func lanes(for plans: [ExtendedCarbPlan]) -> [UUID: Int] {
        var laneEnds: [Date] = []
        var result: [UUID: Int] = [:]
        let ordered = plans.sorted { ($0.start, $0.createdAt) < ($1.start, $1.createdAt) }
        for plan in ordered {
            let lane: Int
            if let free = laneEnds.firstIndex(where: { $0.addingTimeInterval(laneGap) <= plan.start }) {
                lane = free
            } else if laneEnds.count < maximumLanes {
                laneEnds.append(plan.end)
                lane = laneEnds.count - 1
            } else {
                lane = laneEnds.indices.min { laneEnds[$0] < laneEnds[$1] } ?? 0
            }
            laneEnds[lane] = max(laneEnds[lane], plan.end)
            result[plan.fpuID] = lane
        }
        return result
    }
}

/// One delivered portion of an extended bolus. Trio delivers portions as automatic boluses, so in the
/// pump history they look like SMBs; this log is how chart and history tell them apart.
struct ExtendedBolusPortion: JSON, Equatable {
    let date: Date
    /// Actual insulin units, as requested from the pump.
    let units: Decimal
    let planID: UUID
}

enum ExtendedBolusPortions {
    /// Portions older than this are dropped from the log (history only shows recent days).
    static let retention: TimeInterval = 10 * 24 * 60 * 60
    /// Time between the cycle that decided a portion and the pump's timestamp of the bolus.
    static let matchTolerance: TimeInterval = 3 * 60

    static func appending(_ portion: ExtendedBolusPortion, to log: [ExtendedBolusPortion]) -> [ExtendedBolusPortion] {
        let cutoff = portion.date.addingTimeInterval(-retention)
        return log.filter { $0.date >= cutoff } + [portion]
    }

    /// Whether an automatic bolus of `amount` at `date` is an extended bolus portion.
    static func isPortion(date: Date, amount: Decimal, in log: [ExtendedBolusPortion]) -> Bool {
        log.contains { portion in
            abs(portion.date.timeIntervalSince(date)) <= matchTolerance && abs(portion.units - amount) < Decimal(string: "0.005")!
        }
    }
}
