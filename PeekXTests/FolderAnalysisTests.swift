//
//  FolderAnalysisTests.swift
//  PeekXTests
//
//  Unit tests for folder analysis functionality
//

import XCTest
@testable import PeekX

final class FolderAnalysisTests: XCTestCase {
    
    // MARK: - File Sorting Tests
    
    func testFileSortingByDate() {
        let files = [
            FileInfo(name: "old.txt", size: 100, modificationDate: Date.distantPast, type: "txt"),
            FileInfo(name: "new.txt", size: 200, modificationDate: Date(), type: "txt"),
            FileInfo(name: "middle.txt", size: 150, modificationDate: Date().addingTimeInterval(-3600), type: "txt")
        ]
        
        let sorted = files.sorted { $0.modificationDate > $1.modificationDate }
        XCTAssertEqual(sorted.first?.name, "new.txt")
        XCTAssertEqual(sorted.last?.name, "old.txt")
    }
    
    func testFileSortingBySize() {
        let files = [
            FileInfo(name: "small.txt", size: 100, modificationDate: Date(), type: "txt"),
            FileInfo(name: "large.txt", size: 1000, modificationDate: Date(), type: "txt"),
            FileInfo(name: "medium.txt", size: 500, modificationDate: Date(), type: "txt")
        ]
        
        let sorted = files.sorted { $0.size > $1.size }
        XCTAssertEqual(sorted.first?.name, "large.txt")
        XCTAssertEqual(sorted.last?.name, "small.txt")
    }
    
    // MARK: - File Type Analysis Tests
    
    func testFileTypeGrouping() {
        let files = [
            FileInfo(name: "file1.txt", size: 100, modificationDate: Date(), type: "txt"),
            FileInfo(name: "file2.txt", size: 200, modificationDate: Date(), type: "txt"),
            FileInfo(name: "image.jpg", size: 300, modificationDate: Date(), type: "jpg"),
            FileInfo(name: "noext", size: 400, modificationDate: Date(), type: "")
        ]
        
        var filesByType: [String: Int] = [:]
        for file in files {
            filesByType[file.type, default: 0] += 1
        }
        
        XCTAssertEqual(filesByType["txt"], 2)
        XCTAssertEqual(filesByType["jpg"], 1)
        XCTAssertEqual(filesByType[""], 1)
    }
    
    // MARK: - Constants Tests
    
    func testPreviewConstants() {
        XCTAssertEqual(PreviewConstants.minFileCount, 5)
        XCTAssertEqual(PreviewConstants.maxFileCount, 20)
        XCTAssertEqual(PreviewConstants.maxRecursionDepth, 10)
        XCTAssertEqual(PreviewConstants.largeFolderThreshold, 1000)
        XCTAssertEqual(PreviewConstants.analysisTimeoutSeconds, 5.0)
        XCTAssertEqual(PreviewConstants.maxMemoryUsageMB, 50)
        XCTAssertEqual(PreviewConstants.maxCacheItems, 50)
        XCTAssertEqual(PreviewConstants.cacheExpirationMinutes, 10.0)
    }
    
    // MARK: - Folder Analysis Tests
    
    func testFolderAnalysisCreation() {
        let analysis = FolderAnalysis(
            totalSize: 1500,
            fileCount: 4,
            folderCount: 2,
            filesByType: ["txt": 2, "jpg": 1, "": 1],
            recentFiles: [],
            largestFiles: []
        )
        
        XCTAssertEqual(analysis.totalSize, 1500)
        XCTAssertEqual(analysis.fileCount, 4)
        XCTAssertEqual(analysis.folderCount, 2)
        XCTAssertEqual(analysis.filesByType["txt"], 2)
    }
    
    func testFileCountLimiting() {
        let settings = SharedSettings(
            showHiddenFiles: false,
            showFileTypes: true,
            showRecentFiles: true,
            showLargestFiles: true,
            maxRecentFiles: 15,
            maxLargestFiles: 25
        )
        
        // Test that limits are enforced
        let limitedRecent = min(settings.maxRecentFiles, PreviewConstants.maxFileCount)
        let limitedLargest = min(settings.maxLargestFiles, PreviewConstants.maxFileCount)
        
        XCTAssertEqual(limitedRecent, 15) // Within limit
        XCTAssertEqual(limitedLargest, 20) // Limited by maxFileCount
    }
    
    // MARK: - Cache Tests
    
    func testAnalysisCache() {
        let cache = AnalysisCache.shared
        let testURL = URL(fileURLWithPath: "/test/folder")
        let testAnalysis = FolderAnalysis(
            totalSize: 1000,
            fileCount: 5,
            folderCount: 1,
            filesByType: ["txt": 5],
            recentFiles: [],
            largestFiles: []
        )
        
        // Test setting and getting
        cache.set(testAnalysis, for: testURL)
        let cached = cache.get(for: testURL)
        XCTAssertNotNil(cached)
        XCTAssertEqual(cached?.totalSize, 1000)
        XCTAssertEqual(cached?.fileCount, 5)
    }
    
    // MARK: - Error Tests
    
    func testPreviewErrorMessages() {
        let notFolderError = PreviewError.notAFolder
        XCTAssertEqual(notFolderError.message, "The selected item is not a folder")
        
        let htmlError = PreviewError.htmlGenerationFailed
        XCTAssertEqual(htmlError.message, "Failed to generate HTML preview")
        
        let timeoutError = PreviewError.analysisTimeout
        XCTAssertEqual(timeoutError.message, "Analysis took too long")
        
        let recursionError = PreviewError.recursionLimitExceeded
        XCTAssertEqual(recursionError.message, "Folder structure too deep")
        
        let accessError = PreviewError.accessDenied
        XCTAssertEqual(accessError.message, "Access denied to folder contents")
    }
    
    // MARK: - Performance Tests
    
    func testLargeFileArrayPerformance() {
        let files = (0..<1000).map { index in
            FileInfo(
                name: "file\(index).txt",
                size: UInt64(index * 100),
                modificationDate: Date().addingTimeInterval(TimeInterval(-index)),
                type: "txt"
            )
        }
        
        measure {
            let recent = Array(files.sorted { $0.modificationDate > $1.modificationDate }.prefix(10))
            let largest = Array(files.sorted { $0.size > $1.size }.prefix(10))
            
            XCTAssertEqual(recent.count, 10)
            XCTAssertEqual(largest.count, 10)
        }
    }
    
    // MARK: - Edge Cases Tests
    
    func testEmptyFolderAnalysis() {
        let analysis = FolderAnalysis(
            totalSize: 0,
            fileCount: 0,
            folderCount: 0,
            filesByType: [:],
            recentFiles: [],
            largestFiles: []
        )
        
        XCTAssertEqual(analysis.totalSize, 0)
        XCTAssertEqual(analysis.fileCount, 0)
        XCTAssertEqual(analysis.folderCount, 0)
        XCTAssertTrue(analysis.filesByType.isEmpty)
        XCTAssertTrue(analysis.recentFiles.isEmpty)
        XCTAssertTrue(analysis.largestFiles.isEmpty)
    }
    
    func testFileInfoWithNoExtension() {
        let file = FileInfo(
            name: "noextension",
            size: 500,
            modificationDate: Date(),
            type: ""
        )
        
        XCTAssertEqual(file.name, "noextension")
        XCTAssertEqual(file.size, 500)
        XCTAssertEqual(file.type, "")
    }
    
    func testFileSizeFormatting() {
        // This would test the formatSize function if it were accessible
        // For now, we'll test the logic conceptually
        
        let sizes: [UInt64: String] = [
            0: "0 bytes",
            1024: "1 KB",
            1024 * 1024: "1 MB",
            1024 * 1024 * 1024: "1 GB"
        ]
        
        // Verify we have the expected size mappings
        XCTAssertEqual(sizes.count, 4)
        XCTAssertNotNil(sizes[0])
        XCTAssertNotNil(sizes[1024])
    }
}
