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


// First-run setup: works out the provider from the API key's prefix, so a new user
// only pastes a key and never picks a provider, URL or model.
enum ProviderSetup {
    static let groqURL = "https://api.groq.com/openai/v1"
    static let groqModel = "openai/gpt-oss-120b"

    // Defaults for a Mac that has never been set up: Groq with its strongest free model.
    static let registeredDefaults: [String: Any] = [
        "backendType": BackendType.openai.rawValue,
        "backendURL": groqURL,
        "selectedModel": groqModel,
    ]

    static var needsKey: Bool {
        let cfg = BackendConfig.current
        return cfg.type != .ollama && !cfg.url.hasPrefix("http://localhost") && cfg.apiKey.trimmed.isEmpty
    }

    // Saves the key under the provider it belongs to and picks that provider's model.
    static func apply(key raw: String) {
        let key = raw.trimmed
        guard !key.isEmpty else { return }
        let match: (BackendType, String, String?)
        if key.hasPrefix("gsk_") {
            match = (.openai, groqURL, groqModel)
        } else if key.hasPrefix("sk-ant-") {
            match = (.anthropic, "https://api.anthropic.com/v1", "claude-sonnet-5-5")
        } else if key.hasPrefix("sk-or-") {
            match = (.openrouter, "https://openrouter.ai/api/v1", nil)
        } else if key.hasPrefix("nvapi-") {
            match = (.openai, "https://integrate.api.nvidia.com/v1", nil)
        } else if key.hasPrefix("sk-") {
            match = (.openai, "https://api.openai.com/v1", "gpt-5-mini")
        } else {
            let cfg = BackendConfig.current   // unknown prefix: keep the current provider
            match = (cfg.type, cfg.url, nil)
        }
        BackendConfig.current = BackendConfig(type: match.0, url: match.1, apiKey: key)
        if let model = match.2 { UserDefaults.standard.set(model, forKey: "selectedModel") }
        else { UserDefaults.standard.removeObject(forKey: "selectedModel") }
    }
}
