import Foundation
import CryptoKit
import Security

// A signed access code made by tools/keygen.py. Layout after "PH1-" (base32):
// 8-byte id · 1-byte unlock time (1-127 = hours, 0x80 | n = n minutes) ·
// 4-byte redeem-by (unix s, 0 = none) · 64-byte Ed25519 signature.
struct AccessCode {
    static let prefix = "PH1"
    let id: String
    let duration: TimeInterval
    let redeemBy: Date?

    enum Failure: Error {
        case format, signature, expired(Date), used

        var message: String {
            switch self {
            case .format:    return "That doesn't look like a Phantom access code. Paste the whole code, starting with PH1-."
            case .signature: return "This code is not valid."
            case .expired(let d):
                return "This code expired on \(DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .short)). Ask for a new one."
            case .used:      return "This code has already been used on this Mac."
            }
        }
    }

    static func parse(_ raw: String) -> Result<AccessCode, Failure> {
        let text = raw.components(separatedBy: .whitespacesAndNewlines).joined().uppercased()
        guard text.hasPrefix(prefix + "-"),
              let bytes = base32Decode(String(text.dropFirst(prefix.count + 1))),
              bytes.count == 13 + 64 else { return .failure(.format) }
        let payload = bytes.prefix(13), signature = bytes.suffix(64)
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: Data(accessPublicKey)),
              key.isValidSignature(signature, for: Data(prefix.utf8) + payload) else { return .failure(.signature) }

        let p = Array(payload)
        let redeem = p[9..<13].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return .success(AccessCode(
            id: p[0..<8].map { String(format: "%02x", $0) }.joined(),
            duration: p[8] & 0x80 != 0 ? TimeInterval(p[8] & 0x7F) * 60 : TimeInterval(p[8]) * 3600,
            redeemBy: redeem == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(redeem))))
    }

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    private static func base32Decode(_ s: String) -> Data? {
        var out = Data(), buffer = 0, bits = 0
        for ch in s {
            guard let v = alphabet.firstIndex(of: ch) else { return nil }
            buffer = (buffer << 5) | v; bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> bits) & 0xFF))
                buffer &= (1 << bits) - 1
            }
        }
        return out
    }
}

// Tracks the 3-hour unlock. State lives in the login Keychain so it survives
// reinstalls and isn't a plain settings file.
final class AccessManager {
    static let shared = AccessManager()

    private struct State: Codable {
        var unlockedUntil: TimeInterval = 0
        var lastSeen: TimeInterval = 0
        var usedIDs: [String] = []
    }

    private var state: State
    private let service: String

    init(service: String = "com.local.phantom.access") {
        self.service = service
        state = State()
        state = load() ?? State()
        checkClock()
    }

    var isUnlocked: Bool { Date().timeIntervalSince1970 < state.unlockedUntil }
    var remaining: TimeInterval { max(0, state.unlockedUntil - Date().timeIntervalSince1970) }

    // Validates and redeems a code; on success the app is unlocked for the code's time.
    func redeem(_ raw: String) -> Result<TimeInterval, AccessCode.Failure> {
        switch AccessCode.parse(raw) {
        case .failure(let f): return .failure(f)
        case .success(let code):
            let now = Date().timeIntervalSince1970
            if let by = code.redeemBy, now > by.timeIntervalSince1970 { return .failure(.expired(by)) }
            if state.usedIDs.contains(code.id) { return .failure(.used) }
            state.usedIDs.append(code.id)
            // A new code adds its time on top of any time still left.
            state.unlockedUntil = max(state.unlockedUntil, now) + code.duration
            state.lastSeen = now
            save()
            return .success(remaining)
        }
    }

    // Call periodically. Moving the clock back to stretch the time locks the app.
    func checkClock() {
        let now = Date().timeIntervalSince1970
        if state.lastSeen - now > 300 { state.unlockedUntil = 0 }
        state.lastSeen = max(state.lastSeen, now)
        save()
    }

    static func describe(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded(.up))
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(max(m, 1)) min"
    }

    // MARK: Keychain

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "state"]
    }

    private func load() -> State? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    // Removes the stored state (used by tests).
    func reset() { SecItemDelete(query as CFDictionary); state = State() }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
