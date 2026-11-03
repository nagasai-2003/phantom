import Foundation

// Turns a provider's model list into chat models, screenshot-capable ones first.
// Hides speech, safety, embedding, image-generation and Arabic-only models.
enum ModelCatalog {
    private static let hidden = [
        "whisper", "tts", "orpheus", "playai", "guard", "safeguard", "allam", "arabic",
        "embed", "moderation", "dall-e", "gpt-image", "sora", "davinci", "babbage",
        "transcribe", "audio", "realtime", "search", "computer-use", "codex",
    ]

    // Model families known to accept images. OpenRouter reports this itself.
    private static let visionHints = [
        "gpt-4o", "gpt-4.1", "gpt-4.5", "gpt-5", "chatgpt-4o", "gpt-4-turbo", "claude",
        "vision", "-vl", "2.5vl", "llama-4", "llava", "gemma3", "gemma-3", "pixtral",
        "minicpm-v", "moondream", "qwen3.8",
    ]

    static func isVision(_ id: String) -> Bool {
        let m = id.lowercased()
        if m.hasPrefix("o1-mini") || m.hasPrefix("o3-mini") { return false }
        if ["o1", "o3", "o4"].contains(where: { m == $0 || m.hasPrefix($0 + "-") }) { return true }
        return visionHints.contains { m.contains($0) }
    }

    // `list` is the provider's raw model array; `idKey` is "id" (OpenAI-style) or "name" (Ollama).
    static func chatModels(_ list: [[String: Any]], idKey: String = "id") -> (all: [String], vision: [String]) {
        var seen = Set<String>(), vision: [String] = [], text: [String] = []
        for m in list {
            guard let id = m[idKey] as? String, seen.insert(id).inserted else { continue }
            let low = id.lowercased()
            if hidden.contains(where: { low.contains($0) }) { continue }
            if (m["active"] as? Bool) == false { continue }
            // Dated snapshots (gpt-4o-2024-08-06) duplicate the plain name.
            if low.range(of: "-[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil { continue }
            let inputs = (m["architecture"] as? [String: Any])?["input_modalities"] as? [String]
            if inputs?.contains("image") ?? isVision(id) { vision.append(id) } else { text.append(id) }
        }
        vision.sort(); text.sort()
        return (vision + text, vision)
    }
}
