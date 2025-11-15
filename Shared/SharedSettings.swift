//
//  SharedSettings.swift
//  PeekX
//
//  Shared settings between main app and Quick Look extension
//

import Foundation

struct SharedSettings: Codable, Equatable {
    var showHiddenFiles: Bool
    var showFileTypes: Bool
    var showRecentFiles: Bool
    var showLargestFiles: Bool
    var maxRecentFiles: Int
    var maxLargestFiles: Int
    
    static let `default` = SharedSettings(
        showHiddenFiles: false,
        showFileTypes: true,
        showRecentFiles: true,
        showLargestFiles: true,
        maxRecentFiles: 10,
        maxLargestFiles: 10
    )
    
    // App Group identifier - IMPORTANT: Update this in your Xcode project capabilities
    static let appGroupIdentifier = "group.altic.PeekX"
    
    static func load() -> SharedSettings {
        // Try to load from App Group, but fail gracefully
        guard let userDefaults = UserDefaults(suiteName: appGroupIdentifier) else {
            print("⚠️ PeekX: App Group not available, using defaults")
            return .default
        }
        
        guard let data = userDefaults.data(forKey: "settings"),
              let settings = try? JSONDecoder().decode(SharedSettings.self, from: data) else {
            print("⚠️ PeekX: No saved settings found, using defaults")
            return .default
        }
        
        print("✅ PeekX: Loaded settings from App Group")
        return settings
    }
    
    func save() {
        guard let userDefaults = UserDefaults(suiteName: SharedSettings.appGroupIdentifier) else {
            return
        }
        
        if let data = try? JSONEncoder().encode(self) {
            userDefaults.set(data, forKey: "settings")
        }
    }
}
