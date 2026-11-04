import Foundation

// Phantom keeps nothing between sessions except the access record (used codes and
// time left). Everything else (API keys, settings, resume, job description, web
// caches) is erased when Phantom quits, and again at launch in case it was force-quit.
enum SessionData {
    static func wipe() {
        let fm = FileManager.default
        let id = Bundle.main.bundleIdentifier ?? "com.local.phantom"
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]

        // Application Support/Phantom: keep only the sealed access files (.<name>.dat).
        let support = library.appendingPathComponent("Application Support/Phantom", isDirectory: true)
        for url in (try? fm.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)) ?? [] {
            let name = url.lastPathComponent
            if name.hasPrefix(".") && name.hasSuffix(".dat") { continue }
            try? fm.removeItem(at: url)
        }

        // Settings and API keys.
        UserDefaults.standard.removePersistentDomain(forName: id)
        UserDefaults.standard.synchronize()

        // Web view storage, network caches and saved window state.
        for path in ["Caches/\(id)", "HTTPStorages/\(id)", "HTTPStorages/\(id).binarycookies",
                     "WebKit/\(id)", "Saved Application State/\(id).savedState"] {
            try? fm.removeItem(at: library.appendingPathComponent(path))
        }

        // Leftover audio chunks and the old empty ~/.ollama-chat folder.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        for url in (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix("phantom_") {
            try? fm.removeItem(at: url)
        }
        let legacy = NSHomeDirectory() + "/.ollama-chat"
        if (try? fm.contentsOfDirectory(atPath: legacy))?.isEmpty == true { try? fm.removeItem(atPath: legacy) }
    }
}
