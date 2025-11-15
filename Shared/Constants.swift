//
//  Constants.swift
//  PeekX
//
//  Shared constants for PeekX app and extension
//

import Foundation

struct PreviewConstants {
    // UI Dimensions
    static let defaultPreviewSize = CGSize(width: 800, height: 600)
    
    // File Analysis Limits
    static let minFileCount = 5
    static let maxFileCount = 20
    static let maxRecursionDepth = 10
    static let largeFolderThreshold = 1000 // files
    
    // Performance Constraints (Quick Look extensions have strict limits)
    static let analysisTimeoutSeconds: TimeInterval = 5.0
    static let maxMemoryUsageMB: UInt64 = 50 // Stay well under 100MB limit
    
    // Cache Settings
    static let maxCacheItems = 50
    static let cacheExpirationMinutes: TimeInterval = 10.0
}

struct PreviewError: LocalizedError {
    let message: String
    
    static let notAFolder = PreviewError(message: "The selected item is not a folder")
    static let htmlGenerationFailed = PreviewError(message: "Failed to generate HTML preview")
    static let recursionLimitExceeded = PreviewError(message: "Folder structure too deep")
    static let analysisTimeout = PreviewError(message: "Analysis took too long")
    static let accessDenied = PreviewError(message: "Access denied to folder contents")
    
    var errorDescription: String? {
        return message
    }
}
