import Foundation

// MARK: - Options shared with the Windows version

/// Highest first, so the first enabled option is always the best supported one.
enum Resolutions {
    static let all: [(value: String, label: String)] = [
        ("3840x2160", "4K"),
        ("2560x1440", "1440p"),
        ("1920x1080", "1080p"),
        ("1280x720", "720p"),
        ("1024x768", "1024x768"),
        ("720x576", "576p"),
        ("720x480", "480p"),
        ("640x480", "640x480"),
    ]

    static func label(_ value: String) -> String {
        all.first { $0.value == value }?.label ?? value
    }

    static func size(_ value: String) -> (width: Int32, height: Int32) {
        let parts = value.split(separator: "x").compactMap { Int32($0) }
        guard parts.count == 2 else { return (1920, 1080) }
        return (parts[0], parts[1])
    }
}

enum FrameRates {
    static let all = [60, 50, 30]
}

enum ScaleMode: String, Codable, CaseIterable, Identifiable {
    case fit, stretch, integer, aspect43

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fit: return "Fit"
        case .stretch: return "Stretch"
        case .integer: return "Pixel"
        case .aspect43: return "4:3"
        }
    }

    var next: ScaleMode {
        let all = ScaleMode.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

enum RetroFilter: String, Codable, CaseIterable, Identifiable {
    case off, scanlines, crt

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Clean"
        case .scanlines: return "Scanlines"
        case .crt: return "CRT"
        }
    }

    /// Matches the mode numbers in ShaderSource.
    var shaderMode: Int32 {
        switch self {
        case .off: return 0
        case .scanlines: return 1
        case .crt: return 2
        }
    }

    var next: RetroFilter {
        let all = RetroFilter.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

// MARK: - Profiles

/// Settings that belong to a profile. Everything else is shared.
struct Profile: Codable, Equatable {
    var resolution = "1920x1080"
    var framerate = 60
    var scaling = ScaleMode.fit
    var filter = RetroFilter.off
    var audioDelay = 0
}

struct NamedProfile: Codable, Equatable, Identifiable {
    var name: String
    var profile: Profile
    var id: String { name }
}

// MARK: - Shared preferences

/// Game audio picked by hand for one capture device.
enum GameAudioChoice: Codable, Equatable {
    case off
    case device(id: String, name: String)
}

struct Prefs: Codable, Equatable {
    var volume = 1.0
    var muted = false
    var lowLatency = false
    var replay = false
    var stats = false
    var micID = ""
    var micLevel = 1.0
    /// Keyed by the capture device's name. Missing means automatic.
    var gameAudio: [String: GameAudioChoice] = [:]
    var videoDevice = ""
}

// MARK: - Storage

/// Everything PortPlay remembers, kept in UserDefaults like the Windows app keeps it in local storage.
final class SettingsStore {
    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private func load<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func save<T: Encodable>(_ key: String, _ value: T) {
        if let data = try? encoder.encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    var profiles: [NamedProfile] {
        get {
            let stored = load("pp.profiles", as: [NamedProfile].self) ?? []
            return stored.isEmpty ? [NamedProfile(name: "Default", profile: Profile())] : stored
        }
        set { save("pp.profiles", newValue) }
    }

    var activeProfile: String {
        get { defaults.string(forKey: "pp.activeProfile") ?? "Default" }
        set { defaults.set(newValue, forKey: "pp.activeProfile") }
    }

    /// The last profile used with each capture device, keyed by device name.
    var deviceProfiles: [String: String] {
        get { load("pp.deviceProfiles", as: [String: String].self) ?? [:] }
        set { save("pp.deviceProfiles", newValue) }
    }

    var prefs: Prefs {
        get { load("pp.prefs", as: Prefs.self) ?? Prefs() }
        set { save("pp.prefs", newValue) }
    }

    var dismissedTips: Set<String> {
        get { Set(defaults.stringArray(forKey: "pp.dismissedTips") ?? []) }
        set { defaults.set(Array(newValue), forKey: "pp.dismissedTips") }
    }
}
