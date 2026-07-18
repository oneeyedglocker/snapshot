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

    /// How much extra slack beyond exportSeconds we keep in RAM, so trimming
    /// to a keyframe on export never comes up short.
    static var bufferSeconds: Double { exportSeconds + 10 }

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

    // MARK: - Hotkey (default: Cmd+Shift+R)

    private static let hotkeyKeyCodeKey = "hotkeyKeyCode"
    private static let hotkeyModifiersKey = "hotkeyModifiers"

    static var hotkeyKeyCode: UInt16 {
        get {
            let stored = defaults.integer(forKey: hotkeyKeyCodeKey)
            return stored == 0 && defaults.object(forKey: hotkeyKeyCodeKey) == nil ? 15 /* 'R' */ : UInt16(stored)
        }
        set { defaults.set(Int(newValue), forKey: hotkeyKeyCodeKey) }
    }

    static var hotkeyModifiers: NSEvent.ModifierFlags {
        get {
            if defaults.object(forKey: hotkeyModifiersKey) == nil {
                return [.command, .shift]
            }
            return NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: hotkeyModifiersKey)))
        }
        set { defaults.set(Int(newValue.rawValue), forKey: hotkeyModifiersKey) }
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
