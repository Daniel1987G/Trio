import Foundation

/// Sends a text prompt to the AI provider chosen for the meal photo analysis (same API key and
/// model) and returns the text answer.
struct AITextClient {
    var session: URLSession = .shared
    static let timeout: TimeInterval = 180

    func complete(
        prompt: String,
        provider: MealPhotoProvider,
        model: String,
        apiKey: String,
        maxTokens: Int = 6000
    ) async throws -> String {
        let request = try Self.request(provider: provider, model: model, apiKey: apiKey, prompt: prompt, maxTokens: maxTokens)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw MealPhotoAnalysisError.http(status: status, message: MealPhotoAnalyzer.errorMessage(from: data))
        }
        return try MealPhotoAnalyzer.extractText(provider: provider, from: data)
    }

    static func request(
        provider: MealPhotoProvider,
        model: String,
        apiKey: String,
        prompt: String,
        maxTokens: Int
    ) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw MealPhotoAnalysisError.missingAPIKey }
        var request: URLRequest
        let body: [String: Any]

        switch provider {
        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": model,
                "max_tokens": maxTokens,
                "messages": [["role": "user", "content": prompt]]
            ]

        case .openAI:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            body = [
                "model": model,
                "max_completion_tokens": maxTokens,
                "messages": [["role": "user", "content": prompt]]
            ]

        case .gemini:
            let escapedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            request = URLRequest(
                url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(escapedModel):generateContent")!
            )
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            body = [
                "contents": [["parts": [["text": prompt]]]],
                "generationConfig": ["maxOutputTokens": maxTokens]
            ]
        }

        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
