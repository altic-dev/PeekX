//
//  PreviewViewController.swift
//  PeekX QuickLook
//
//  Created by PeekX
//

import Cocoa
import Quartz
import UniformTypeIdentifiers
import WebKit

@objc(PreviewViewController)
class PreviewViewController: NSViewController, QLPreviewingController {
    
    private var webView: WKWebView!
    private var iconCache: [String: String] = [:]
    
    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        NSLog("🎯 PeekX: PreviewViewController initialized!")
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        NSLog("🎯 PeekX: PreviewViewController initialized from coder!")
    }
    
    override func loadView() {
        NSLog("🎯 PeekX: loadView called!")
        
        // Create a simple view
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        
        // Create WebView for displaying HTML
        webView = WKWebView(frame: containerView.bounds)
        webView.autoresizingMask = [.width, .height]
        
        containerView.addSubview(webView)
        
        self.view = containerView
        NSLog("🎯 PeekX: View created with WebView!")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        NSLog("🎯 PeekX: ViewDidLoad called!")
    }
    
    // MARK: - QLPreviewingController Protocol
    
    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        NSLog("🚀 PeekX: preparePreviewOfFile CALLED!")
        NSLog("🔍 PeekX: URL: \(url.path)")
        
        let folderName = url.lastPathComponent
        NSLog("📂 PeekX: Folder name: \(folderName)")
        
        // Enumerate files in background
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let fileManager = FileManager.default
                let contents = try fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
                
                // Sort: folders first, then alphabetically
                let sortedContents = contents.sorted { item1, item2 in
                    let isDir1 = (try? item1.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    let isDir2 = (try? item2.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    
                    if isDir1 != isDir2 {
                        return isDir1  // Folders first
                    }
                    return item1.lastPathComponent.localizedStandardCompare(item2.lastPathComponent) == .orderedAscending
                }
                
                // Performance optimization: use array instead of string concatenation
                var fileRowsArray: [String] = []
                fileRowsArray.reserveCapacity(min(sortedContents.count, 500))
                
                var totalSize: Int64 = 0
                let itemCount = contents.count
                var folderCount = 0
                var fileCount = 0
                
                // Quick pass to calculate stats and build data
                var itemsData: [(name: String, isFolder: Bool, size: Int64, date: String, kind: String, path: String)] = []
                
                for itemURL in sortedContents.prefix(500) {
                    let name = itemURL.lastPathComponent
                    let resourceValues = try itemURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey, .contentModificationDateKey])
                    let isFolder = resourceValues.isDirectory ?? false
                    let size = Int64(resourceValues.fileSize ?? 0)
                    let modDate = resourceValues.contentModificationDate ?? Date()
                    
                    if isFolder {
                        folderCount += 1
                    } else {
                        fileCount += 1
                        totalSize += size
                    }
                    
                    let sizeText = isFolder ? "—" : self.formatBytes(size)
                    let kindText = isFolder ? "Folder" : (resourceValues.contentType?.localizedDescription ?? "File")
                    let dateText = self.formatDate(modDate)
                    
                    itemsData.append((
                        name: name,
                        isFolder: isFolder,
                        size: size,
                        date: dateText,
                        kind: kindText,
                        path: itemURL.path
                    ))
                }
                
                // Use placeholder icons for initial render (FAST!)
                let placeholderFolder = "📁"
                let placeholderFile = "📄"
                
                for item in itemsData {
                    let placeholder = item.isFolder ? placeholderFolder : placeholderFile
                    fileRowsArray.append("""
                    <tr data-path="\(item.path)" data-isfolder="\(item.isFolder)">
                        <td><span class="icon-placeholder">\(placeholder)</span> \(item.name)</td>
                        <td>\(item.date)</td>
                        <td>\(item.isFolder ? "—" : self.formatBytes(item.size))</td>
                        <td>\(item.kind)</td>
                    </tr>
                    """)
                }
                
                let fileRows = fileRowsArray.joined()
                
                // Get folder icon for header (only this one upfront)
                let folderIconURL = self.getCachedIconDataURL(for: url, isFolder: true)
                
                NSLog("📊 PeekX: Found \(itemCount) items (\(folderCount) folders, \(fileCount) files)")
                
                // Better info text with file/folder breakdown
                let infoText = "\(self.formatBytes(totalSize)) · \(folderCount) folders, \(fileCount) files"
                let limitWarning = itemCount > 500 ? "<div class=\"footer\">Showing first 500 of \(itemCount) items</div>" : ""
                
                let html = """
                <!DOCTYPE html>
                <html>
                <head>
                    <meta charset="UTF-8">
                    <style>
                        * { margin: 0; padding: 0; box-sizing: border-box; }
                        body {
                            font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', 'SF Pro Text', sans-serif;
                            background: #ffffff;
                            color: #000000;
                            margin: 0;
                            padding: 16px;
                        }
                        .header {
                            display: flex;
                            align-items: center;
                            gap: 12px;
                            margin-bottom: 16px;
                            padding: 8px 0;
                            border-bottom: 1px solid #e5e5e5;
                        }
                        .header img { width: 32px; height: 32px; }
                        .header .title { 
                            font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif;
                            font-size: 20px; 
                            font-weight: 600; 
                            color: #000;
                            letter-spacing: -0.02em;
                        }
                        .header .info { font-size: 13px; color: #86868b; }
                        table { 
                            width: 100%; 
                            border-collapse: collapse;
                            border-radius: 6px;
                            overflow: hidden;
                        }
                        th {
                            background: #fafafa;
                            padding: 6px 12px;
                            text-align: left;
                            font-size: 11px;
                            font-weight: 600;
                            color: #86868b;
                            border-bottom: 1px solid #e5e5e5;
                            text-transform: uppercase;
                            letter-spacing: 0.5px;
                            cursor: pointer;
                            user-select: none;
                            position: relative;
                            transition: background-color 0.15s ease;
                        }
                        th:hover {
                            background: #f0f0f0;
                        }
                        th.sorted-asc::after {
                            content: ' ▲';
                            font-size: 9px;
                            color: #007aff;
                        }
                        th.sorted-desc::after {
                            content: ' ▼';
                            font-size: 9px;
                            color: #007aff;
                        }
                        td {
                            padding: 6px 12px;
                            font-size: 13px;
                            line-height: 1.5;
                            border-bottom: 1px solid #f5f5f5;
                        }
                        td:nth-child(3) {
                            text-align: right;
                            font-variant-numeric: tabular-nums;
                        }
                        td img { 
                            vertical-align: middle; 
                            margin-right: 8px;
                            display: inline-block;
                        }
                        .icon-placeholder {
                            display: inline-block;
                            width: 16px;
                            text-align: center;
                            font-size: 14px;
                            margin-right: 8px;
                        }
                        tbody tr {
                            transition: background-color 0.15s ease;
                        }
                        tbody tr:nth-child(even) { background: #fafafa; }
                        tbody tr:hover { 
                            background: #e8f2fe;
                            box-shadow: inset 0 0 0 1px rgba(0, 122, 255, 0.2);
                        }
                        .footer {
                            text-align: center;
                            padding: 16px;
                            color: #86868b;
                            font-size: 13px;
                        }
                        
                        /* Dark mode support */
                        @media (prefers-color-scheme: dark) {
                            body {
                                background: #1e1e1e;
                                color: #ffffff;
                            }
                            .header {
                                border-bottom: 1px solid #3a3a3a;
                            }
                            .header .title {
                                color: #ffffff;
                            }
                            .header .info {
                                color: #98989d;
                            }
                            th {
                                background: #2a2a2a;
                                color: #98989d;
                                border-bottom: 1px solid #3a3a3a;
                            }
                            th:hover {
                                background: #353535;
                            }
                            td {
                                border-bottom: 1px solid #2a2a2a;
                            }
                            tbody tr:nth-child(even) {
                                background: #252525;
                            }
                            tbody tr:hover {
                                background: #37474f;
                                box-shadow: inset 0 0 0 1px rgba(100, 150, 200, 0.3);
                            }
                            .footer {
                                color: #98989d;
                            }
                        }
                    </style>
                </head>
                <body>
                    <div class="header">
                        <img src="\(folderIconURL)" width="32" height="32">
                        <div>
                            <div class="title">\(folderName)</div>
                            <div class="info">\(infoText)</div>
                        </div>
                    </div>
                    <table id="fileTable">
                        <thead>
                            <tr>
                                <th onclick="sortTable(0)" class="sorted-asc">Name</th>
                                <th onclick="sortTable(1)">Date Modified</th>
                                <th onclick="sortTable(2)">Size</th>
                                <th onclick="sortTable(3)">Kind</th>
                            </tr>
                        </thead>
                        <tbody>
                            \(fileRows)
                        </tbody>
                    </table>
                    \(limitWarning)
                    
                    <script>
                    let currentSort = { column: 0, ascending: true };
                    
                    function sortTable(columnIndex) {
                        const table = document.getElementById('fileTable');
                        const tbody = table.querySelector('tbody');
                        const rows = Array.from(tbody.querySelectorAll('tr'));
                        
                        // Toggle sort direction if clicking same column
                        if (currentSort.column === columnIndex) {
                            currentSort.ascending = !currentSort.ascending;
                        } else {
                            currentSort.column = columnIndex;
                            currentSort.ascending = true;
                        }
                        
                        // Remove all sort indicators
                        table.querySelectorAll('th').forEach(th => {
                            th.classList.remove('sorted-asc', 'sorted-desc');
                        });
                        
                        // Add sort indicator to clicked column
                        const clickedHeader = table.querySelectorAll('th')[columnIndex];
                        clickedHeader.classList.add(currentSort.ascending ? 'sorted-asc' : 'sorted-desc');
                        
                        // Add animation during sort
                        tbody.style.transition = 'opacity 0.1s ease';
                        tbody.style.opacity = '0.7';
                        
                        // Sort rows
                        rows.sort((a, b) => {
                            let aVal = a.cells[columnIndex].textContent.trim();
                            let bVal = b.cells[columnIndex].textContent.trim();
                            
                            // Special handling for different columns
                            if (columnIndex === 0) { // Name - ignore icon
                                aVal = aVal.substring(aVal.indexOf(' ') + 1);
                                bVal = bVal.substring(bVal.indexOf(' ') + 1);
                                return currentSort.ascending ? 
                                    aVal.localeCompare(bVal, undefined, {numeric: true, sensitivity: 'base'}) :
                                    bVal.localeCompare(aVal, undefined, {numeric: true, sensitivity: 'base'});
                            } else if (columnIndex === 1) { // Date
                                const aDate = new Date(aVal);
                                const bDate = new Date(bVal);
                                return currentSort.ascending ? aDate - bDate : bDate - aDate;
                            } else if (columnIndex === 2) { // Size
                                const aSize = parseSize(aVal);
                                const bSize = parseSize(bVal);
                                return currentSort.ascending ? aSize - bSize : bSize - aSize;
                            } else { // Kind
                                return currentSort.ascending ? 
                                    aVal.localeCompare(bVal) : 
                                    bVal.localeCompare(aVal);
                            }
                        });
                        
                        // Re-append rows in sorted order
                        rows.forEach(row => tbody.appendChild(row));
                        
                        // Restore opacity after sort
                        setTimeout(() => {
                            tbody.style.opacity = '1';
                        }, 50);
                    }
                    
                    function parseSize(sizeStr) {
                        if (sizeStr === '—') return -1; // Folders come first when sorting by size ascending
                        
                        const units = { 'bytes': 1, 'KB': 1024, 'MB': 1024*1024, 'GB': 1024*1024*1024 };
                        const match = sizeStr.match(/([\\d,.]+)\\s*(\\w+)/);
                        if (!match) return 0;
                        
                        const value = parseFloat(match[1].replace(',', ''));
                        const unit = match[2];
                        return value * (units[unit] || 1);
                    }
                    </script>
                </body>
                </html>
                """
                
                // Load HTML on main thread
                DispatchQueue.main.async {
                    self.webView.loadHTMLString(html, baseURL: nil)
                    NSLog("✅ PeekX: HTML loaded with file list!")
                    handler(nil)
                }
                
            } catch {
                NSLog("❌ PeekX: Error reading folder: \(error)")
                handler(error)
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func getCachedIconDataURL(for url: URL, isFolder: Bool) -> String {
        // Create cache key based on file extension or folder
        let cacheKey: String
        if isFolder {
            cacheKey = "__folder__"
        } else {
            cacheKey = url.pathExtension.lowercased().isEmpty ? "__file__" : url.pathExtension.lowercased()
        }
        
        // Return cached icon if available
        if let cached = iconCache[cacheKey] {
            return cached
        }
        
        // Generate and cache
        let iconURL = getIconDataURL(for: url)
        iconCache[cacheKey] = iconURL
        return iconURL
    }
    
    private func getIconDataURL(for url: URL) -> String {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        
        guard let tiffData = icon.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return ""
        }
        
        let base64 = pngData.base64EncodedString()
        return "data:image/png;base64,\(base64)"
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }
}
