import Foundation
import Testing
@testable import Trio

@Suite("Meal Photo Analysis") struct MealPhotoAnalysisTests {
    private let sample = """
    {"is_food": true,
     "items": [{"name": "Pizza Margherita", "grams": 350, "carbs": 95.4, "fat": 28.2, "protein": 31},
               {"name": "Salat", "grams": "80", "carbs": "3,2", "fat": 9, "protein": 1}],
     "total": {"carbs": 99, "fat": 37, "protein": 32},
     "confidence": "Medium",
     "notes": "Ölmenge geschätzt"}
    """

    @Test("Parses the JSON answer, including numbers as strings") func parse() throws {
        let analysis = try MealPhotoAnalysis.parse(sample)
        #expect(analysis.items.count == 2)
        #expect(analysis.items[1].grams == 80)
        #expect(analysis.items[1].carbs == Decimal(string: "3.2")!)
        #expect(analysis.carbs == 99)
        #expect(analysis.fat == 37)
        #expect(analysis.protein == 32)
        #expect(analysis.confidence == .medium)
        #expect(analysis.notes == "Ölmenge geschätzt")
    }

    @Test("FPU = (fat × 9 + protein × 4) / 100") func fpu() throws {
        let analysis = try MealPhotoAnalysis.parse(sample)
        // 37 × 9 + 32 × 4 = 461 kcal
        #expect(analysis.fpu == Decimal(string: "4.61")!)
        #expect(MealPhotoAnalysis.fpu(fat: 10, protein: 25) == Decimal(string: "1.9")!)
    }

    @Test("Tolerates code fences and text around the JSON") func fenced() throws {
        let analysis = try MealPhotoAnalysis.parse("Here you go:\n```json\n\(sample)\n```\nEnjoy")
        #expect(analysis.carbs == 99)
    }

    @Test("Missing totals are summed from the items, missing confidence counts as low") func missingTotals() throws {
        let text =
            #"{"items": [{"name": "A", "carbs": 10.4, "fat": 1, "protein": 2}, {"name": "B", "carbs": 5, "fat": 0, "protein": 0}]}"#
        let analysis = try MealPhotoAnalysis.parse(text)
        #expect(analysis.carbs == 15)
        #expect(analysis.confidence == .low)
    }

    @Test("Negative values are clamped to zero") func negatives() throws {
        let text =
            #"{"items": [{"name": "A", "carbs": -5, "fat": 3, "protein": 1}], "total": {"carbs": -5, "fat": 3, "protein": 1}}"#
        #expect(try MealPhotoAnalysis.parse(text).carbs == 0)
    }

    @Test("No food or no JSON is an error") func errors() {
        #expect(throws: MealPhotoAnalysisError.self) {
            try MealPhotoAnalysis.parse(#"{"is_food": false, "items": [], "notes": "A cat"}"#)
        }
        #expect(throws: MealPhotoAnalysisError.self) {
            try MealPhotoAnalysis.parse("I cannot help with that.")
        }
        #expect(throws: MealPhotoAnalysisError.self) {
            try MealPhotoAnalysis.parse(#"{"items": [], "total": {"carbs": 0, "fat": 0, "protein": 0}}"#)
        }
    }

    // MARK: - Requests

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any])
    }

    @Test("Anthropic request") func anthropicRequest() throws {
        let request = try MealPhotoAnalyzer.request(
            provider: .anthropic,
            model: "m",
            apiKey: "k",
            imageBase64: "AAA",
            prompt: "p"
        )
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "k")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let json = try body(request)
        #expect(json["model"] as? String == "m")
        let content = ((json["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
        #expect(content.first?["type"] as? String == "image")
        #expect((content.first?["source"] as? [String: Any])?["data"] as? String == "AAA")
    }

    @Test("OpenAI request") func openAIRequest() throws {
        let request = try MealPhotoAnalyzer.request(provider: .openAI, model: "m", apiKey: "k", imageBase64: "AAA", prompt: "p")
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        let json = try body(request)
        #expect((json["response_format"] as? [String: Any])?["type"] as? String == "json_object")
        let content = ((json["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
        let url = (content.last?["image_url"] as? [String: Any])?["url"] as? String
        #expect(url == "data:image/jpeg;base64,AAA")
    }

    @Test("Gemini request") func geminiRequest() throws {
        let request = try MealPhotoAnalyzer.request(
            provider: .gemini,
            model: "gemini-x",
            apiKey: "k",
            imageBase64: "AAA",
            prompt: "p"
        )
        #expect(
            request.url?.absoluteString ==
                "https://generativelanguage.googleapis.com/v1beta/models/gemini-x:generateContent"
        )
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "k")
        let json = try body(request)
        #expect((json["generationConfig"] as? [String: Any])?["responseMimeType"] as? String == "application/json")
    }

    @Test("An empty key is refused before anything is sent") func emptyKey() {
        #expect(throws: MealPhotoAnalysisError.missingAPIKey) {
            try MealPhotoAnalyzer.request(provider: .openAI, model: "m", apiKey: "", imageBase64: "A", prompt: "p")
        }
    }

    // MARK: - Responses

    @Test("Extracts the text from each provider's response") func responses() throws {
        let anthropic = Data(#"{"content": [{"type": "text", "text": "{\"a\":1}"}]}"#.utf8)
        #expect(try MealPhotoAnalyzer.extractText(provider: .anthropic, from: anthropic) == #"{"a":1}"#)

        let openAI = Data(#"{"choices": [{"message": {"content": "{\"a\":1}"}}]}"#.utf8)
        #expect(try MealPhotoAnalyzer.extractText(provider: .openAI, from: openAI) == #"{"a":1}"#)

        let gemini = Data(#"{"candidates": [{"content": {"parts": [{"text": "{\"a\":1}"}]}}]}"#.utf8)
        #expect(try MealPhotoAnalyzer.extractText(provider: .gemini, from: gemini) == #"{"a":1}"#)

        #expect(throws: MealPhotoAnalysisError.emptyResponse) {
            try MealPhotoAnalyzer.extractText(provider: .openAI, from: Data(#"{"choices": []}"#.utf8))
        }
    }

    @Test("Reads the provider's error message") func errorMessage() {
        let data = Data(#"{"error": {"message": "invalid x-api-key", "type": "authentication_error"}}"#.utf8)
        #expect(MealPhotoAnalyzer.errorMessage(from: data) == "invalid x-api-key")
    }
}
