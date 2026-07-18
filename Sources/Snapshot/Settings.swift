import AppKit
import Foundation

enum TargetKind: String, Codable {
    case app
    case display
}

struct PersistedTarget: Codable {
    var kind: TargetKind
    /// Bundle identifier when kind == .app, or the CGDirectDisplayID (as a string) when kind == .display.
    var identifier: String
    var displayName: String
}

enum Settings {
    private static let defaults = UserDefaults.standard

    static let availableClipLengths: [Int] = [15, 30, 60]

    private static let exportSecondsKey = "exportSeconds"

    /// What a clip actually contains, in seconds. User-configurable via the
    /// menu (Clip Length submenu); persisted across launches.
    static var exportSeconds: Double {
        get {
            let stored = defaults.integer(forKey: exportSecondsKey)
            return availableClipLengths.contains(stored) ? Double(stored) : 30
        }
        set { defaults.set(Int(newValue), forKey: exportSecondsKey) }
    }

    /// How much we keep in RAM. Sized to the *longest* available clip length
    /// (not the current default) plus keyframe slack, so "Save Full Length"
    /// always has a full-length clip available regardless of what the quick
    /// default is currently set to.
    static var bufferSeconds: Double {
        Double(availableClipLengths.max() ?? Int(exportSeconds)) + 10
    }

    static let keyframeIntervalSeconds: Double = 2
    static let frameRate: Int32 = 30
    static let videoBitrate: Int = 8_000_000 // ~8 Mbps, good 1080p quality
    static let audioSampleRate: Double = 48_000
    static let audioChannels: Int = 2

    static var outputDirectory: URL = {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let dir = movies.appendingPathComponent("Snapshot Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Hotkeys

    private static let saveClipKeyCodeKey = "hotkeyKeyCode"
    private static let saveClipModifiersKey = "hotkeyModifiers"
    private static let saveFullKeyCodeKey = "fullLengthHotkeyKeyCode"
    private static let saveFullModifiersKey = "fullLengthHotkeyModifiers"

    private static func storedKeyCode(_ key: String, default defaultCode: UInt16) -> UInt16 {
        defaults.object(forKey: key) == nil ? defaultCode : UInt16(defaults.integer(forKey: key))
    }

    private static func storedModifiers(_ key: String, default defaultMods: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        defaults.object(forKey: key) == nil ? defaultMods : NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: key)))
    }

    /// Default: Cmd+Shift+R. Saves a clip at the current default length.
    static var saveClipHotkey: KeyCombo {
        get {
            KeyCombo(
                keyCode: storedKeyCode(saveClipKeyCodeKey, default: 15 /* 'R' */),
                modifiers: storedModifiers(saveClipModifiersKey, default: [.command, .shift])
            )
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: saveClipKeyCodeKey)
            defaults.set(Int(newValue.modifiers.rawValue), forKey: saveClipModifiersKey)
        }
    }

    /// Default: Cmd+Shift+F. Always saves the longest available clip length.
    static var saveFullLengthHotkey: KeyCombo {
        get {
            KeyCombo(
                keyCode: storedKeyCode(saveFullKeyCodeKey, default: 3 /* 'F' */),
                modifiers: storedModifiers(saveFullModifiersKey, default: [.command, .shift])
            )
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: saveFullKeyCodeKey)
            defaults.set(Int(newValue.modifiers.rawValue), forKey: saveFullModifiersKey)
        }
    }

    // MARK: - Last selected capture target

    private static let targetKey = "captureTarget"

    static var savedTarget: PersistedTarget? {
        get {
            guard let data = defaults.data(forKey: targetKey) else { return nil }
            return try? JSONDecoder().decode(PersistedTarget.self, from: data)
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: targetKey)
                return
            }
            defaults.set(try? JSONEncoder().encode(newValue), forKey: targetKey)
        }
    }
}
