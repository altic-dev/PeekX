//
//  PeekXApp.swift
//  PeekX
//
//  Copyright © 2025 ALTIC. All rights reserved.
//

import SwiftUI
import AppKit
import UserNotifications

@main
struct PeekXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        requestNotificationPermission()
        checkAndRefreshExtensionIfNeeded()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            NSApplication.shared.terminate(nil)
        }
    }
    
    private func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }
    
    private func checkAndRefreshExtensionIfNeeded() {
        let defaults = UserDefaults.standard
        let lastVersionKey = "PeekXLastLaunchedVersion"
        
        guard let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else {
            return
        }
        
        let currentFullVersion = "\(currentVersion).\(currentBuild)"
        let lastVersion = defaults.string(forKey: lastVersionKey)
        
        if lastVersion != currentFullVersion {
            refreshQuickLookExtension()
            defaults.set(currentFullVersion, forKey: lastVersionKey)
            
            if lastVersion != nil {
                showUpdateNotification()
            }
        }
    }
    
    private func refreshQuickLookExtension() {
        let resetTask = Process()
        resetTask.launchPath = "/usr/bin/qlmanage"
        resetTask.arguments = ["-r", "cache"]
        try? resetTask.run()
        resetTask.waitUntilExit()
        
        let killTask = Process()
        killTask.launchPath = "/usr/bin/killall"
        killTask.arguments = ["quicklookd"]
        try? killTask.run()
    }
    
    private func showUpdateNotification() {
        let center = UNUserNotificationCenter.current()
        
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                return
            }
            
            let content = UNMutableNotificationContent()
            content.title = "PeekX Updated"
            content.body = "Quick Look extension has been refreshed"
            
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            
            center.add(request) { _ in }
        }
    }
}
