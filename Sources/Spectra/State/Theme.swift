import SwiftUI

/// User-facing appearance settings, persisted in UserDefaults. Mirrors Prism's
/// theme controls: appearance (Auto/Light/Dark, Auto following the system),
/// an accent colour and a text-size scale.
@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    enum Appearance: String, CaseIterable, Identifiable {
        case auto, light, dark
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var colorScheme: ColorScheme? {
            switch self {
            case .auto: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    enum Accent: String, CaseIterable, Identifiable {
        case music, indigo, teal, pink, orange, green, red, purple, blue
        var id: String { rawValue }
        var color: Color {
            switch self {
            case .music: return Color(red: 0.98, green: 0.18, blue: 0.28)   // Music.app red
            case .indigo: return .indigo
            case .teal: return .teal
            case .pink: return .pink
            case .orange: return .orange
            case .green: return .green
            case .red: return .red
            case .purple: return .purple
            case .blue: return .blue
            }
        }
        var label: String { rawValue.capitalized }
    }

    enum TextSize: String, CaseIterable, Identifiable {
        case small, standard, large
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var dynamicTypeSize: DynamicTypeSize {
            switch self {
            case .small: return .small
            case .standard: return .medium
            case .large: return .xLarge
            }
        }
    }

    @Published var appearance: Appearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "theme.appearance") }
    }
    @Published var accent: Accent {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: "theme.accent") }
    }
    @Published var textSize: TextSize {
        didSet { UserDefaults.standard.set(textSize.rawValue, forKey: "theme.textSize") }
    }

    private init() {
        let d = UserDefaults.standard
        appearance = Appearance(rawValue: d.string(forKey: "theme.appearance") ?? "auto") ?? .auto
        accent = Accent(rawValue: d.string(forKey: "theme.accent") ?? "music") ?? .music
        textSize = TextSize(rawValue: d.string(forKey: "theme.textSize") ?? "standard") ?? .standard
    }
}
