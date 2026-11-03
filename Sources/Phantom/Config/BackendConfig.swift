import Foundation

enum BackendType: String {
    case ollama     = "ollama"
    case openai     = "openai"
    case anthropic  = "anthropic"
    case openrouter = "openrouter"
}

struct BackendConfig {
    var type:   BackendType
    var url:    String
    var apiKey: String

    static var current: BackendConfig {
        get {
            let d = UserDefaults.standard
            return BackendConfig(
                type:   BackendType(rawValue: d.string(forKey: "backendType") ?? "") ?? .ollama,
                url:    d.string(forKey: "backendURL")    ?? "http://localhost:11434",
                apiKey: savedKey(for: d.string(forKey: "backendURL") ?? "http://localhost:11434")
            )
        }
        set {
            let d = UserDefaults.standard
            d.set(newValue.type.rawValue, forKey: "backendType")
            d.set(newValue.url,           forKey: "backendURL")
            d.set(newValue.apiKey,        forKey: "backendAPIKey")
            d.set(newValue.apiKey,        forKey: "apiKey|" + newValue.url)
        }
    }

    // Each provider URL keeps its own key, so switching Groq ↔ OpenAI doesn't lose either.
    static func savedKey(for url: String) -> String {
        let d = UserDefaults.standard
        if let k = d.string(forKey: "apiKey|" + url) { return k }
        // Keys saved before per-provider keys existed belong to the URL saved with them.
        return url == d.string(forKey: "backendURL") ? (d.string(forKey: "backendAPIKey") ?? "") : ""
    }
}
