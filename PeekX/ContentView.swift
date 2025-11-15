//
//  ContentView.swift
//  PeekX
//
//  Created by Barathwaj Anandan on 11/15/25.
//

import SwiftUI

struct ContentView: View {
    @State private var settings = SharedSettings.load()
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 16) {
                    Image(systemName: "folder.fill.badge.questionmark")
                        .font(.system(size: 80))
                        .foregroundStyle(
                            .linearGradient(
                                colors: [.purple, .blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .padding(.top, 40)
                    
                    Text("PeekX")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(
                            .linearGradient(
                                colors: [.purple, .blue],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    
                    Text("Enhanced Folder Quick Look")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    
                    // Extension status
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Extension Ready")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(20)
                }
                .padding(.bottom, 40)
                
                // Settings Section
                VStack(alignment: .leading, spacing: 20) {
                    Text("Settings")
                        .font(.title2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 24)
                    
                    VStack(spacing: 16) {
                        // Display Options
                        SettingCard(title: "Display Options") {
                            SettingToggle(
                                icon: "chart.pie.fill",
                                title: "Show File Types",
                                subtitle: "Display breakdown of files by type",
                                isOn: $settings.showFileTypes
                            )
                            
                            Divider()
                                .padding(.leading, 50)
                            
                            SettingToggle(
                                icon: "clock.fill",
                                title: "Show Recent Files",
                                subtitle: "Display recently modified files",
                                isOn: $settings.showRecentFiles
                            )
                            
                            if settings.showRecentFiles {
                                HStack {
                                    Spacer()
                                        .frame(width: 50)
                                    
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Maximum recent files: \(settings.maxRecentFiles)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        
                                        Slider(value: Binding(
                                            get: { Double(settings.maxRecentFiles) },
                                            set: { settings.maxRecentFiles = Int($0) }
                                        ), in: 5...20, step: 1)
                                    }
                                    .padding(.trailing, 16)
                                }
                                .padding(.vertical, 8)
                            }
                            
                            Divider()
                                .padding(.leading, 50)
                            
                            SettingToggle(
                                icon: "arrow.down.circle.fill",
                                title: "Show Largest Files",
                                subtitle: "Display files sorted by size",
                                isOn: $settings.showLargestFiles
                            )
                            
                            if settings.showLargestFiles {
                                HStack {
                                    Spacer()
                                        .frame(width: 50)
                                    
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Maximum largest files: \(settings.maxLargestFiles)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        
                                        Slider(value: Binding(
                                            get: { Double(settings.maxLargestFiles) },
                                            set: { settings.maxLargestFiles = Int($0) }
                                        ), in: 5...20, step: 1)
                                    }
                                    .padding(.trailing, 16)
                                }
                                .padding(.vertical, 8)
                            }
                        }
                        
                        // Advanced Options
                        SettingCard(title: "Advanced") {
                            SettingToggle(
                                icon: "eye.slash.fill",
                                title: "Show Hidden Files",
                                subtitle: "Include hidden files in analysis",
                                isOn: $settings.showHiddenFiles
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 30)
                
                // Instructions Section
                VStack(alignment: .leading, spacing: 16) {
                    Text("How to Use")
                        .font(.title2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 24)
                    
                    InstructionCard(
                        number: "1",
                        title: "Enable Extension",
                        description: "Go to System Settings → Privacy & Security → Extensions → Quick Look to enable PeekX"
                    )
                    
                    InstructionCard(
                        number: "2",
                        title: "Select a Folder",
                        description: "Navigate to any folder in Finder"
                    )
                    
                    InstructionCard(
                        number: "3",
                        title: "Press Space",
                        description: "Press the Space bar to see the enhanced Quick Look preview"
                    )
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
                
                // Footer
                VStack(spacing: 8) {
                    Button(action: {
                        openSystemExtensions()
                    }) {
                        HStack {
                            Image(systemName: "gear")
                            Text("Open Extension Settings")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            LinearGradient(
                                colors: [.purple, .blue],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .foregroundColor(.white)
                        .cornerRadius(12)
                        .font(.headline)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)
                    
                    Text("Version 1.0")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .onChange(of: settings) { _, newValue in
            newValue.save()
        }
    }
    
    private func openSystemExtensions() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.extensions") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Supporting Views

struct SettingCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 16)
            
            VStack(spacing: 0) {
                content
            }
            .padding(.bottom, 12)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }
}

struct SettingToggle: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(
                    .linearGradient(
                        colors: [.purple, .blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 34, height: 34)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)
                
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct InstructionCard: View {
    let number: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.purple, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 40, height: 40)
                
                Text(number)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }
}

#Preview {
    ContentView()
        .frame(width: 600, height: 800)
}
