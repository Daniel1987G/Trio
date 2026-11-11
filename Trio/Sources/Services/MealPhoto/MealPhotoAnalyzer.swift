import Foundation
import UIKit

/// Where the photo analysis settings live: the API keys in the Keychain, provider and model names
/// in UserDefaults (they are not secret).
struct MealPhotoSettingsStore {
    let keychain: Keychain
    var defaults: UserDefaults = .standard

    private static let providerKey = "mealPhoto.provider"
    private static func modelKey(_ provider: MealPhotoProvider) -> String { "mealPhoto.model.\(provider.rawValue)" }
    private static func apiKeyKey(_ provider: MealPhotoProvider) -> String { "mealPhoto.apiKey.\(provider.rawValue)" }

    var provider: MealPhotoProvider {
        get { defaults.string(forKey: Self.providerKey).flatMap(MealPhotoProvider.init(rawValue:)) ?? .anthropic }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.providerKey) }
    }

    func model(for provider: MealPhotoProvider) -> String {
        let stored = defaults.string(forKey: Self.modelKey(provider))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (stored?.isEmpty ?? true) ? provider.defaultModel : stored!
    }

    func setModel(_ model: String, for provider: MealPhotoProvider) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(trimmed.isEmpty ? nil : trimmed, forKey: Self.modelKey(provider))
    }

    func apiKey(for provider: MealPhotoProvider) -> String? {
        let key = keychain.getValue(String.self, forKey: Self.apiKeyKey(provider))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (key?.isEmpty ?? true) ? nil : key
    }

    func setAPIKey(_ key: String?, for provider: MealPhotoProvider) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            keychain.setValue(trimmed, forKey: Self.apiKeyKey(provider))
        } else {
            keychain.removeObject(forKey: Self.apiKeyKey(provider))
        }
    }

    /// The feature is offered only when the selected provider has a key.
    var isConfigured: Bool { apiKey(for: provider) != nil }
}

/// Sends a meal photo to the selected AI provider and returns its estimate.
struct MealPhotoAnalyzer {
    var session: URLSession = .shared
    static let timeout: TimeInterval = 60

    func analyze(
        image: UIImage,
        provider: MealPhotoProvider,
        model: String,
        apiKey: String,
        languageCode: String = Locale.current.language.languageCode?.identifier ?? "en"
    ) async throws -> MealPhotoAnalysis {
        guard let jpeg = Self.preparedJPEG(from: image) else { throw MealPhotoAnalysisError.imageEncodingFailed }
        let request = try Self.request(
            provider: provider,
            model: model,
            apiKey: apiKey,
            imageBase64: jpeg.base64EncodedString(),
            prompt: MealPhotoAnalysis.prompt(languageCode: languageCode)
        )

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw MealPhotoAnalysisError.http(status: status, message: Self.errorMessage(from: data))
        }
        let text = try Self.extractText(provider: provider, from: data)
        return try MealPhotoAnalysis.parse(text)
    }

    // MARK: - Image

    /// Long side at most 1568 px (enough detail, small upload), JPEG quality 0.8.
    static func preparedJPEG(from image: UIImage, maxSide: CGFloat = 1568) -> Data? {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxSide / longest)
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.8)
    }

    // MARK: - Requests

    static func request(
        provider: MealPhotoProvider,
        model: String,
        apiKey: String,
        imageBase64: String,
        prompt: String
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
                "max_tokens": 2000,
                "messages": [[
                    "role": "user",
                    "content": [
                        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": imageBase64]],
                        ["type": "text", "text": prompt]
                    ]
                ]]
            ]

        case .openAI:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            body = [
                "model": model,
                "max_completion_tokens": 4000,
                "response_format": ["type": "json_object"],
                "messages": [[
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(imageBase64)", "detail": "high"]]
                    ]
                ]]
            ]

        case .gemini:
            let escapedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            request = URLRequest(
                url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(escapedModel):generateContent")!
            )
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            body = [
                "contents": [[
                    "parts": [
                        ["text": prompt],
                        ["inline_data": ["mime_type": "image/jpeg", "data": imageBase64]]
                    ]
                ]],
                "generationConfig": ["responseMimeType": "application/json"]
            ]
        }

        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Responses

    /// The model's text answer from each provider's response format.
    static func extractText(provider: MealPhotoProvider, from data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MealPhotoAnalysisError.unreadableResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }

        let text: String?
        switch provider {
        case .anthropic:
            let blocks = object["content"] as? [[String: Any]] ?? []
            text = blocks.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined()
        case .openAI:
            let choices = object["choices"] as? [[String: Any]]
            text = (choices?.first?["message"] as? [String: Any])?["content"] as? String
        case .gemini:
            let candidates = object["candidates"] as? [[String: Any]]
            let parts = ((candidates?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
            text = parts.compactMap { $0["text"] as? String }.joined()
        }

        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MealPhotoAnalysisError.emptyResponse
        }
        return text
    }

    /// Readable message from an error response (all three use `{"error": {"message": ...}}`).
    static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String
        {
            return message
        }
        let raw = String(decoding: data.prefix(300), as: UTF8.self)
        return raw.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: 0) : raw
    }
}
