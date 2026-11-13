import Foundation
import Testing
import SwiftUI
@testable import Vory

@MainActor
struct AppThemeTests {
    @Test func defaultPresetsHaveWhiteContrastForeground() {
        for preset in AppTheme.accents {
            #expect(preset.contrastForeground == .white)
        }
    }

    @Test func customAccentResolvesValidHex() {
        let suite = UserDefaults.standard
        let previous = suite.string(forKey: AppTheme.customHexKey)
        defer {
            if let previous { suite.set(previous, forKey: AppTheme.customHexKey) }
            else { suite.removeObject(forKey: AppTheme.customHexKey) }
        }

        suite.set("#FF8800", forKey: AppTheme.customHexKey)
        let custom = AppTheme.accent("custom")
        #expect(custom.id == "custom")
        #expect(custom.name == "Custom")
        #expect(custom.contrastForeground == .white)
    }

    @Test func customAccentFallsBackOnCorruptHex() {
        let suite = UserDefaults.standard
        let previous = suite.string(forKey: AppTheme.customHexKey)
        defer {
            if let previous { suite.set(previous, forKey: AppTheme.customHexKey) }
            else { suite.removeObject(forKey: AppTheme.customHexKey) }
        }

        suite.set("not-a-color", forKey: AppTheme.customHexKey)
        let fallback = AppTheme.accent("custom")
        #expect(fallback.id == "custom")
        #expect(fallback.color == AppTheme.accents[0].color)
        #expect(fallback.contrastForeground == .white)
    }

    @Test func lightCustomColorProvidesDarkContrastForeground() {
        let suite = UserDefaults.standard
        let previous = suite.string(forKey: AppTheme.customHexKey)
        defer {
            if let previous { suite.set(previous, forKey: AppTheme.customHexKey) }
            else { suite.removeObject(forKey: AppTheme.customHexKey) }
        }

        suite.set("#FFFFFF", forKey: AppTheme.customHexKey)
        let custom = AppTheme.accent("custom")
        #expect(custom.contrastForeground == .black)
    }

    @Test func currentForegroundMatchesSelectedAccent() {
        let suite = UserDefaults.standard
        let prevAccent = suite.string(forKey: AppTheme.accentKey)
        let prevHex = suite.string(forKey: AppTheme.customHexKey)
        defer {
            if let prevAccent { suite.set(prevAccent, forKey: AppTheme.accentKey) }
            else { suite.removeObject(forKey: AppTheme.accentKey) }
            if let prevHex { suite.set(prevHex, forKey: AppTheme.customHexKey) }
            else { suite.removeObject(forKey: AppTheme.customHexKey) }
        }

        suite.set("blue", forKey: AppTheme.accentKey)
        #expect(AppTheme.currentForeground == .white)

        suite.set("custom", forKey: AppTheme.accentKey)
        suite.set("#FFFF00", forKey: AppTheme.customHexKey)
        #expect(AppTheme.currentForeground == .black)
    }

    @Test func themeObserverUpdatesAppThemeCurrentLive() {
        let prevAccent = ThemeObserver.shared.accentID
        let prevHex = ThemeObserver.shared.customHex
        defer {
            ThemeObserver.shared.accentID = prevAccent
            ThemeObserver.shared.customHex = prevHex
        }

        ThemeObserver.shared.accentID = "green"
        #expect(AppTheme.current == AppTheme.accents.first { $0.id == "green" }?.color)

        ThemeObserver.shared.accentID = "custom"
        ThemeObserver.shared.customHex = "#123456"
        #expect(AppTheme.current == Color(hex: "#123456"))
    }
}
