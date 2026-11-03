import Carbon

private var _hotKeyCallbacks: [UInt32: () -> Void] = [:]

private func hotKeyProc(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var hkID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &hkID)
    guard status == noErr else { return status }
    _hotKeyCallbacks[hkID.id]?()
    return noErr
}

// System-wide shortcuts that work while another app (Zoom, Meet…) is focused.
class GlobalHotKey {
    static let toggleID: UInt32 = 1

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?

    private static let keyCodeMap: [String: UInt32] = [
        "a": 0,  "s": 1,  "d": 2,  "f": 3,  "h": 4,  "g": 5,
        "z": 6,  "x": 7,  "c": 8,  "v": 9,  "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
        "j": 38, "k": 40, "n": 45, "m": 46,
    ]

    init(callback: @escaping () -> Void) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyProc, 1, &spec, nil, &handler)
        register(RecordingShortcut.toggle, id: Self.toggleID, callback: callback)
    }

    // Re-registers the show/hide shortcut after it changes in Settings.
    func register(_ shortcut: RecordingShortcut) {
        guard let cb = _hotKeyCallbacks[Self.toggleID] else { return }
        register(shortcut, id: Self.toggleID, callback: cb)
    }

    func register(_ shortcut: RecordingShortcut, id: UInt32, callback: @escaping () -> Void) {
        if let r = refs[id] { UnregisterEventHotKey(r); refs[id] = nil }
        _hotKeyCallbacks[id] = callback
        guard !shortcut.key.isEmpty,
              let keyCode = Self.keyCodeMap[shortcut.key.lowercased()] else { return }
        var carbonMods: UInt32 = 0
        if shortcut.modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if shortcut.modifiers.contains(.option)  { carbonMods |= UInt32(optionKey) }
        if shortcut.modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
        if shortcut.modifiers.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
        let hkID = EventHotKeyID(signature: OSType(0x5645494C), id: id)
        var ref: EventHotKeyRef?
        if RegisterEventHotKey(keyCode, carbonMods, hkID, GetApplicationEventTarget(), 0, &ref) == noErr,
           let ref = ref {
            refs[id] = ref
        } else {
            print("[hotkey] could not register \(shortcut.displayString) (already used by another app?)")
        }
    }

    deinit {
        refs.values.forEach { UnregisterEventHotKey($0) }
        if let h = handler { RemoveEventHandler(h) }
    }
}
