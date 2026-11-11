import Foundation

/// AI provider used to estimate a meal from a photo.
enum MealPhotoProvider: String, Codable, CaseIterable, Identifiable {
    case anthropic
    case openAI
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic Claude"
        case .openAI: return "OpenAI"
        case .gemini: return "Google Gemini"
        }
    }

    /// A vision-capable model; editable in the settings because providers rename models often.
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-5-5"
        case .openAI: return "gpt-6-astra"
        case .gemini: return "gemini-3.8-flash"
        }
    }

    /// Where the user gets an API key.
    var keyURL: URL {
        switch self {
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")!
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")!
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")!
        }
    }
}

/// An AI estimate of a meal. Every value is an estimate the user must check; nothing is dosed from it
/// directly. Amounts are grams.
struct MealPhotoAnalysis: Codable, Equatable {
    enum Confidence: String, Codable, Equatable {
        case low
        case medium
        case high
    }

    struct Item: Codable, Equatable, Identifiable {
        var id: String { name + "\(grams ?? 0)" }
        let name: String
        let grams: Decimal?
        let carbs: Decimal
        let fat: Decimal
        let protein: Decimal
    }

    let items: [Item]
    let carbs: Decimal
    let fat: Decimal
    let protein: Decimal
    let confidence: Confidence
    let notes: String?

    /// Fat-protein units: 1 FPU = 100 kcal from fat (9 kcal/g) and protein (4 kcal/g).
    var fpu: Decimal {
        Self.fpu(fat: fat, protein: protein)
    }

    static func fpu(fat: Decimal, protein: Decimal) -> Decimal {
        MealCarbType.fpu(fat: fat, protein: protein)
    }

    /// Several photos of one meal (main dish, side, dessert): items and totals add up, the confidence is
    /// the lowest one and the notes are kept. nil without any analysis.
    static func combined(_ parts: [MealPhotoAnalysis]) -> MealPhotoAnalysis? {
        guard let first = parts.first else { return nil }
        guard parts.count > 1 else { return first }
        let rank: [Confidence: Int] = [.low: 0, .medium: 1, .high: 2]
        let notes = parts.compactMap(\.notes)
        return MealPhotoAnalysis(
            items: parts.flatMap(\.items),
            carbs: parts.reduce(0) { $0 + $1.carbs },
            fat: parts.reduce(0) { $0 + $1.fat },
            protein: parts.reduce(0) { $0 + $1.protein },
            confidence: parts.map(\.confidence).min { rank[$0, default: 0] < rank[$1, default: 0] } ?? .low,
            notes: notes.isEmpty ? nil : notes.joined(separator: "\n")
        )
    }
}

// MARK: - Prompt and parsing

enum MealPhotoAnalysisError: LocalizedError, Equatable {
    case missingAPIKey
    case imageEncodingFailed
    case http(status: Int, message: String)
    case emptyResponse
    case unreadableResponse(String)
    case notFood(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return String(
                localized: "No API key is set for the selected provider. Add one in Settings → Meal Settings → Meal Photo Analysis."
            )
        case .imageEncodingFailed:
            return String(localized: "The photo could not be prepared for analysis.")
        case let .http(status, message):
            return String(localized: "The AI provider returned an error (\(status)): \(message)")
        case .emptyResponse:
            return String(localized: "The AI provider returned no answer.")
        case let .unreadableResponse(detail):
            return String(localized: "The answer of the AI provider could not be read: \(detail)")
        case let .notFood(reason):
            return String(localized: "No meal was recognized in the photo. \(reason)")
        }
    }
}

extension MealPhotoAnalysis {
    /// Instructions sent with every photo. Asks for one JSON object, nothing else.
    static func prompt(languageCode: String) -> String {
        """
        You estimate the nutrition of a meal from a photo for a person with type 1 diabetes who uses the \
        numbers to plan insulin. Be realistic, not optimistic: do not underestimate portions, and account \
        for hidden fat (oil, butter, cream, cheese, dressings) and sauces that are typical for the dish.

        Identify every food on the photo, estimate its weight in grams from the plate, cutlery and \
        packaging for scale, and its carbohydrates, fat and protein in grams. Count only what is \
        visible on the photo. Fibre is not part of carbohydrates.

        Answer with exactly one JSON object and nothing else, using this structure:
        {
          "is_food": true,
          "items": [{"name": "string", "grams": 0, "carbs": 0, "fat": 0, "protein": 0}],
          "total": {"carbs": 0, "fat": 0, "protein": 0},
          "confidence": "low" | "medium" | "high",
          "notes": "string"
        }
        Numbers are grams, without units. "confidence" is low when portions or ingredients cannot be \
        judged reliably (mixed dishes, sauces, partly hidden food). "notes" briefly names what is \
        uncertain. If the photo shows no food, set "is_food" to false, "items" to [] and explain in \
        "notes". Write "name" and "notes" in the language with ISO code "\(languageCode)".
        """
    }

    /// Parses the model's text. Tolerates code fences and text around the JSON object, and numbers
    /// given as strings; totals are recomputed from the items when missing.
    static func parse(_ text: String) throws -> MealPhotoAnalysis {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            throw MealPhotoAnalysisError.unreadableResponse(String(text.prefix(200)))
        }
        let json = String(text[start ... end])
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw MealPhotoAnalysisError.unreadableResponse(String(json.prefix(200)))
        }

        let notes = (object["notes"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let isFood = object["is_food"] as? Bool, !isFood {
            throw MealPhotoAnalysisError.notFood(notes ?? "")
        }

        let items: [Item] = (object["items"] as? [[String: Any]] ?? []).compactMap { raw in
            let name = (raw["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return nil }
            return Item(
                name: name,
                grams: number(raw["grams"]).map { rounded($0, scale: 0) },
                carbs: rounded(number(raw["carbs"]) ?? 0, scale: 1),
                fat: rounded(number(raw["fat"]) ?? 0, scale: 1),
                protein: rounded(number(raw["protein"]) ?? 0, scale: 1)
            )
        }

        let total = object["total"] as? [String: Any]
        func totalValue(_ key: String, _ itemValue: (Item) -> Decimal) -> Decimal {
            if let value = number(total?[key]) { return rounded(value, scale: 0) }
            return rounded(items.reduce(0) { $0 + itemValue($1) }, scale: 0)
        }

        let confidence = (object["confidence"] as? String).flatMap { Confidence(rawValue: $0.lowercased()) } ?? .low

        let analysis = MealPhotoAnalysis(
            items: items,
            carbs: totalValue("carbs", \.carbs),
            fat: totalValue("fat", \.fat),
            protein: totalValue("protein", \.protein),
            confidence: confidence,
            notes: notes
        )
        guard analysis.carbs > 0 || analysis.fat > 0 || analysis.protein > 0 else {
            throw MealPhotoAnalysisError.notFood(notes ?? "")
        }
        return analysis
    }

    /// Non-negative number from a JSON value (number or numeric string).
    private static func number(_ value: Any?) -> Decimal? {
        let decimal: Decimal?
        switch value {
        case let number as NSNumber:
            decimal = number.decimalValue
        case let string as String:
            decimal = Decimal(string: string.replacingOccurrences(of: ",", with: "."))
        default:
            decimal = nil
        }
        guard let decimal, decimal.isFinite else { return nil }
        return max(0, decimal)
    }

    private static func rounded(_ value: Decimal, scale: Int) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, scale, .plain)
        return result
    }
}
