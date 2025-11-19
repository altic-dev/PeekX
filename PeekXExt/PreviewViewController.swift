// PeekX - Folder Preview Extension for macOS
// Copyright © 2025 ALTIC. All rights reserved.

import Cocoa
import Quartz
import UniformTypeIdentifiers
import QuickLook
import ImageIO
import WebKit
import QuartzCore  // For CATransaction

// MARK: - Debug Logger
final class DebugLogger {
    static let shared = DebugLogger()
    
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.peekx.logger", qos: .utility)
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let maxSize: UInt64 = 256 * 1024 // 256 KB
    
    private init() {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        fileURL = temp.appendingPathComponent("PeekXExt.log")
    }
    
    func log(_ message: String) {
        let timestamp = formatter.string(from: Date())
        let entry = "[\(timestamp)] \(message)\n"
        queue.async {
            if let data = entry.data(using: .utf8) {
                self.append(data)
            }
            NSLog(message)
        }
    }
    
    func locationDescription() -> String { fileURL.path }
    
    private func append(_ data: Data) {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) == false {
                try data.write(to: fileURL, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            }
            pruneIfNeeded()
        } catch {
            NSLog("PeekX logger error: \(error.localizedDescription)")
        }
    }
    
    private func pruneIfNeeded() {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let size = attributes[.size] as? UInt64,
            size > maxSize
        else { return }
        
        if let data = try? Data(contentsOf: fileURL) {
            let trimmed = data.suffix(Int(maxSize / 2))
            try? trimmed.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - Custom Outline View

/// Protocol for handling keyboard events in the outline view
protocol FinderOutlineViewKeyboardDelegate: AnyObject {
    func outlineView(_ outlineView: FinderOutlineView, handle event: NSEvent) -> Bool
}

/// Custom outline view that intercepts keyboard events for QuickLook-specific shortcuts
final class FinderOutlineView: NSOutlineView {
    weak var keyboardDelegate: FinderOutlineViewKeyboardDelegate?
    
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
    
    override func keyDown(with event: NSEvent) {
        if keyboardDelegate?.outlineView(self, handle: event) == true {
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - File Item Model

/// Represents a file or folder in the preview hierarchy
final class FileItem: NSObject, QLPreviewItem {
    let url: URL
    let name: String
    let isFolder: Bool
    let size: Int64
    let modificationDate: Date
    let contentType: UTType?
    weak var parent: FileItem?
    var icon: NSImage?
    var children: [FileItem]?
    var childrenLoaded = false
    
    // Cached formatted strings to avoid repeated formatting
    private var _formattedSize: String?
    private var _formattedDate: String?
    private var _kindDescription: String?
    private var _previewInfo: String?
    
    // Cached type checks for fast preview decisions
    lazy var isImage: Bool = contentType?.conforms(to: .image) ?? false
    lazy var isText: Bool = contentType?.conforms(to: .text) ?? false || url.pathExtension.lowercased() == "md"
    lazy var isMedia: Bool = contentType?.conforms(to: .audiovisualContent) ?? false
    
    init(url: URL, resourceValues: URLResourceValues, parent: FileItem? = nil) {
        self.url = url
        self.name = url.lastPathComponent
        self.isFolder = resourceValues.isDirectory ?? false
        self.size = Int64(resourceValues.fileSize ?? 0)
        self.modificationDate = resourceValues.contentModificationDate ?? Date()
        self.contentType = resourceValues.contentType
        self.parent = parent
        super.init()
    }
    
    var kindDescription: String {
        if let cached = _kindDescription {
            return cached
        }
        let desc = isFolder ? "Folder" : (contentType?.localizedDescription ?? "File")
        _kindDescription = desc
        return desc
    }
    
    // Lazy formatted size - computed once and cached
    func formattedSize(using formatter: ByteCountFormatter) -> String {
        if let cached = _formattedSize {
            return cached
        }
        let formatted = isFolder ? "—" : formatter.string(fromByteCount: size)
        _formattedSize = formatted
        return formatted
    }
    
    // Lazy formatted date - computed once and cached
    func formattedDate(using formatter: DateFormatter) -> String {
        if let cached = _formattedDate {
            return cached
        }
        let formatted = formatter.string(from: modificationDate)
        _formattedDate = formatted
        return formatted
    }
    
    // Pre-build complete preview info string
    func previewInfo(sizeFormatter: ByteCountFormatter, dateFormatter: DateFormatter) -> String {
        if let cached = _previewInfo {
            return cached
        }
        var segments: [String] = []
        if !isFolder {
            segments.append(formattedSize(using: sizeFormatter))
        }
        segments.append(kindDescription)
        segments.append(formattedDate(using: dateFormatter))
        let info = segments.joined(separator: " · ")
        _previewInfo = info
        return info
    }
    
    func setChildren(_ children: [FileItem]) {
        self.children = children
        self.childrenLoaded = true
        for child in children {
            child.parent = self
        }
    }
    
    func resetChildren() {
        children = nil
        childrenLoaded = false
    }
    
    var previewItemURL: URL? { url }
    var previewItemTitle: String { name }
}

// MARK: - Preview View Controller

/// Main view controller for the QuickLook folder preview extension
@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {
    
    // MARK: - Filter Types
    
    private enum FilterType: Int {
        case all, folders, images, documents, media
        
        func matches(_ item: FileItem) -> Bool {
            switch self {
            case .all:
                return true
            case .folders:
                return item.isFolder
            case .images:
                return item.isImage
            case .documents:
                if item.isFolder { return false }
                // Document = not image and not media
                return !item.isImage && !item.isMedia
            case .media:
                return item.isMedia
            }
        }
    }
    
    // MARK: - UI Components
    
    private var mainStack: NSStackView!
    private var scrollView: NSScrollView!
    private var splitView: NSSplitView!
    private var outlineView: FinderOutlineView!
    private var headerView: NSView!
    private var iconImageView: NSImageView!
    private var titleLabel: NSTextField!
    private var infoLabel: NSTextField!
    private var controlsStack: NSStackView!
    private var filterControl: NSSegmentedControl!
    private var previewPane: NSView!
    private var pathBarView: NSView!
    private var pathControl: NSPathControl!
    private var previewImageView: NSImageView!
    private var webView: WKWebView!
    private var singleFileWebView: WKWebView!  // Separate WebView for single file mode
    private var previewSpinner: NSProgressIndicator!
    private var previewTitleLabel: NSTextField!
    private var previewInfoLabel: NSTextField!
    private var previewMessageLabel: NSTextField!
    
    // MARK: - Performance Caches
    
    private let iconCache = NSCache<NSString, NSImage>()
    private let iconLoadQueue = DispatchQueue(label: "com.peekx.iconloader", qos: .userInitiated, attributes: .concurrent)
    
    // MARK: - Data State
    
    private var rootItems: [FileItem] = []
    private var filterType: FilterType = .all
    private var currentSortDescriptor: NSSortDescriptor? = NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))
    private var visibleRootItems: [FileItem] = []
    private var previewedItem: FileItem?
    private var previewImageLoadTask: DispatchWorkItem?
    private var previewRootURL: URL?
    private var didSetInitialSplitPosition = false
    private var singleFileMode = false
    private var previewUpdateWorkItem: DispatchWorkItem?
    
    // MARK: - Formatters
    
    private lazy var byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()
    
    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
    
    // MARK: - View Lifecycle
    
    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        container.translatesAutoresizingMaskIntoConstraints = false
        
        // Main Vertical Stack
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .centerX
        stack.distribution = .fill
        self.mainStack = stack
        
        headerView = createHeaderView()
        controlsStack = createControlsStack()
        
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        
        outlineView = FinderOutlineView()
        outlineView.translatesAutoresizingMaskIntoConstraints = false
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.headerView = NSTableHeaderView()
        outlineView.focusRingType = .none
        outlineView.selectionHighlightStyle = .regular
        outlineView.rowSizeStyle = .default
        outlineView.allowsColumnReordering = false
        outlineView.allowsColumnResizing = true
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.keyboardDelegate = self
        outlineView.menu = contextMenu
        outlineView.menu?.delegate = self
        
        scrollView.documentView = outlineView
        
        splitView = NSSplitView()
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(scrollView)
        previewPane = createPreviewPane()
        splitView.addArrangedSubview(previewPane)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        splitView.arrangedSubviews[0].widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        splitView.arrangedSubviews[1].widthAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true
        
        mainStack.addArrangedSubview(headerView)
        mainStack.addArrangedSubview(controlsStack)
        mainStack.addArrangedSubview(splitView)

        container.addSubview(mainStack)
        
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            
            headerView.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            controlsStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            splitView.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        ])
        
        // Content priorities to ensure SplitView fills space
        headerView.setContentHuggingPriority(.required, for: .vertical)
        controlsStack.setContentHuggingPriority(.required, for: .vertical)
        splitView.setContentHuggingPriority(.defaultLow, for: .vertical)
        
        // Create standalone WebView for single-file mode
        let singleFileConfig = WKWebViewConfiguration()
        singleFileWebView = WKWebView(frame: .zero, configuration: singleFileConfig)
        singleFileWebView.translatesAutoresizingMaskIntoConstraints = false
        singleFileWebView.isHidden = true
        singleFileWebView.setValue(false, forKey: "drawsBackground")
        container.addSubview(singleFileWebView)
        
        NSLayoutConstraint.activate([
            singleFileWebView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 16),
            singleFileWebView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            singleFileWebView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            singleFileWebView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])
        
        createColumns()
        updatePreview(for: nil)
        self.view = container
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        outlineView.window?.makeFirstResponder(outlineView)
    }
    
    override func viewDidLayout() {
        super.viewDidLayout()
        if !didSetInitialSplitPosition {
            didSetInitialSplitPosition = true
            setDefaultSplitPosition()
        }
    }
    
    // MARK: - UI Builders
    private func createHeaderView() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        
        iconImageView = NSImageView()
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.imageScaling = .scaleProportionallyDown
        
        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        
        infoLabel = NSTextField(labelWithString: "")
        infoLabel.font = NSFont.systemFont(ofSize: 13)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        
        view.addSubview(iconImageView)
        view.addSubview(titleLabel)
        view.addSubview(infoLabel)
        
        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            iconImageView.topAnchor.constraint(equalTo: view.topAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 48),
            iconImageView.heightAnchor.constraint(equalToConstant: 48),
            
            titleLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            
            infoLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            infoLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            infoLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            infoLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4)
        ])
        
        return view
    }
    
    private func createControlsStack() -> NSStackView {
        filterControl = NSSegmentedControl(labels: ["All", "Folders", "Images", "Docs", "Media"], trackingMode: .selectOne, target: self, action: #selector(filterChanged(_:)))
        filterControl.selectedSegment = FilterType.all.rawValue
        filterControl.translatesAutoresizingMaskIntoConstraints = false
        
        let stack = NSStackView(views: [filterControl])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        
        // Ensure the stack itself doesn't force a specific width if not needed, 
        // but we can center the filter control inside it.
        
        NSLayoutConstraint.activate([
            filterControl.widthAnchor.constraint(equalToConstant: 320)
        ])
        
        return stack
    }
    
    private func setDefaultSplitPosition() {
        view.layoutSubtreeIfNeeded()
        let totalWidth = splitView.bounds.width
        guard totalWidth > 0 else { return }
        let previewMin: CGFloat = 360
        let outlineMin: CGFloat = 320
        let desiredLeft = max(outlineMin, min(totalWidth - previewMin, totalWidth * 0.4))
        splitView.setPosition(desiredLeft, ofDividerAt: 0)
    }
    
    private func createColumns() {
        outlineView.tableColumns.forEach { outlineView.removeTableColumn($0) }
        
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.minWidth = 250
        nameColumn.width = 380
        nameColumn.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))
        outlineView.addTableColumn(nameColumn)
        outlineView.outlineTableColumn = nameColumn
        
        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateColumn.title = "Date Modified"
        dateColumn.minWidth = 160
        dateColumn.width = 200
        dateColumn.sortDescriptorPrototype = NSSortDescriptor(key: "date", ascending: false)
        outlineView.addTableColumn(dateColumn)
        
        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeColumn.title = "Size"
        sizeColumn.minWidth = 80
        sizeColumn.width = 120
        sizeColumn.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: false)
        outlineView.addTableColumn(sizeColumn)
        
        let kindColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kind"))
        kindColumn.title = "Kind"
        kindColumn.minWidth = 140
        kindColumn.width = 180
        kindColumn.sortDescriptorPrototype = NSSortDescriptor(key: "kind", ascending: true)
        outlineView.addTableColumn(kindColumn)
    }
    
    private func createPreviewPane() -> NSView {
        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false
        
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        
        let imageContainer = NSView()
        imageContainer.translatesAutoresizingMaskIntoConstraints = false
        imageContainer.wantsLayer = true
        imageContainer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        imageContainer.layer?.cornerRadius = 8
        imageContainer.layer?.masksToBounds = true
        
        previewImageView = NSImageView()
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.imageAlignment = .alignCenter
        
        let webConfig = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: webConfig)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isHidden = true
        webView.setValue(false, forKey: "drawsBackground")
        
        previewSpinner = NSProgressIndicator()
        previewSpinner.translatesAutoresizingMaskIntoConstraints = false
        previewSpinner.style = .spinning
        previewSpinner.controlSize = .large
        previewSpinner.isDisplayedWhenStopped = false
        
        imageContainer.addSubview(previewImageView)
        imageContainer.addSubview(webView)
        imageContainer.addSubview(previewSpinner)
        
        let flexibleWidth = imageContainer.widthAnchor.constraint(equalToConstant: 0)
        flexibleWidth.priority = .defaultLow
        NSLayoutConstraint.activate([
            previewImageView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
            previewImageView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
            previewImageView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
            previewImageView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),
            
            webView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
            webView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
            webView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),
            
            previewSpinner.centerXAnchor.constraint(equalTo: imageContainer.centerXAnchor),
            previewSpinner.centerYAnchor.constraint(equalTo: imageContainer.centerYAnchor),
            
            imageContainer.heightAnchor.constraint(equalToConstant: 340),
            flexibleWidth
        ])
        
        previewTitleLabel = NSTextField(labelWithString: "No Selection")
        previewTitleLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        previewTitleLabel.lineBreakMode = .byTruncatingTail
        
        previewInfoLabel = NSTextField(labelWithString: "Select a file to preview.")
        previewInfoLabel.font = NSFont.systemFont(ofSize: 12)
        previewInfoLabel.textColor = .secondaryLabelColor
        previewInfoLabel.lineBreakMode = .byWordWrapping
        
        previewMessageLabel = NSTextField(labelWithString: "")
        previewMessageLabel.font = NSFont.systemFont(ofSize: 12)
        previewMessageLabel.textColor = .tertiaryLabelColor
        previewMessageLabel.lineBreakMode = .byWordWrapping
        previewMessageLabel.isHidden = true
        
        stack.addArrangedSubview(imageContainer)
        stack.addArrangedSubview(previewTitleLabel)
        stack.addArrangedSubview(previewInfoLabel)
        stack.addArrangedSubview(previewMessageLabel)
        stack.setCustomSpacing(4, after: previewTitleLabel)
        
        pane.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: pane.topAnchor),
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: pane.bottomAnchor)
        ])
        
        return pane
    }
    
    private func createPathBar() -> NSView {
        let bar = NSVisualEffectView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.material = .underPageBackground
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 6
        bar.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        
        pathControl = NSPathControl()
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.pathStyle = .standard
        pathControl.focusRingType = .none
        pathControl.font = NSFont.systemFont(ofSize: 12)
        pathControl.isEnabled = true
        pathControl.isEditable = false
        bar.addSubview(pathControl)
        
        NSLayoutConstraint.activate([
            pathControl.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            pathControl.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            pathControl.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])
        
        return bar
    }
    
    
    // MARK: - Preview Loading
    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Check if directory
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                if values.isDirectory == false {
                    // Single file mode - HELLO WORLD TEST
                    DebugLogger.shared.log("✅ DETECTED SINGLE FILE: \(url.lastPathComponent)")
                    NSLog("✅ PeekX: DETECTED SINGLE FILE: \(url.lastPathComponent)")
                    
                    DispatchQueue.main.async {
                        // SINGLE FILE MODE
                        self.applySingleFileLayout(true)
                        
                        // Load markdown content asynchronously
                        DispatchQueue.global(qos: .userInitiated).async {
                            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? "Could not read file."
                            // Escape the content for safe embedding in JS
                            let escapedContent = content
                                .replacingOccurrences(of: "\\", with: "\\\\")
                                .replacingOccurrences(of: "`", with: "\\`")
                                .replacingOccurrences(of: "$", with: "\\$")
                            
                            let html = """
                            <!DOCTYPE html>
                            <html>
                            <head>
                                <meta charset="utf-8">
                                <meta name="viewport" content="width=device-width, initial-scale=1">
                                <script src="https://cdn.jsdelivr.net/npm/marked@11.1.1/marked.min.js"></script>
                                <style>
                                    :root { color-scheme: light dark; }
                                    body {
                                        margin: 0;
                                        padding: 20px 60px 40px 60px;
                                        font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                                        font-size: 15px;
                                        line-height: 1.6;
                                        color: #1d1d1f;
                                        background: #ffffff;
                                    }
                                    @media (prefers-color-scheme: dark) {
                                        body { color: #e5e5e5; background: #1e1e1e; }
                                        a { color: #58a6ff; }
                                        code { background: rgba(110,118,129,0.2); color: #e5e5e5; }
                                        pre { background: rgba(110,118,129,0.15); border-color: rgba(110,118,129,0.3); }
                                        h1, h2 { border-bottom-color: rgba(110,118,129,0.3); }
                                        th { background: rgba(110,118,129,0.15); }
                                        td, th { border-color: rgba(110,118,129,0.3); }
                                        blockquote { border-left-color: rgba(110,118,129,0.4); color: #a0a0a0; }
                                    }
                                    h1, h2, h3, h4, h5, h6 { margin-top: 24px; margin-bottom: 16px; font-weight: 600; line-height: 1.25; }
                                    h1 { font-size: 2em; border-bottom: 1px solid #e1e4e8; padding-bottom: 8px; }
                                    h2 { font-size: 1.5em; border-bottom: 1px solid #e1e4e8; padding-bottom: 6px; }
                                    h3 { font-size: 1.25em; }
                                    p { margin: 0 0 16px 0; }
                                    a { color: #0969da; text-decoration: none; }
                                    a:hover { text-decoration: underline; }
                                    code {
                                        font-family: "SF Mono", Monaco, Menlo, Consolas, monospace;
                                        font-size: 13px;
                                        background: rgba(175,184,193,0.2);
                                        padding: 2px 6px;
                                        border-radius: 4px;
                                    }
                                    pre {
                                        background: #f6f8fa;
                                        padding: 16px;
                                        border-radius: 8px;
                                        overflow-x: auto;
                                        border: 1px solid #e1e4e8;
                                        margin: 16px 0;
                                    }
                                    pre code { background: none; padding: 0; }
                                    ul, ol { margin: 0 0 16px 0; padding-left: 32px; }
                                    li { margin: 4px 0; }
                                    blockquote {
                                        margin: 0 0 16px 0;
                                        padding: 0 16px;
                                        border-left: 4px solid #d0d7de;
                                        color: #57606a;
                                    }
                                    table { border-collapse: collapse; width: 100%; margin: 16px 0; }
                                    th, td { border: 1px solid #d0d7de; padding: 8px 12px; text-align: left; }
                                    th { background: #f6f8fa; font-weight: 600; }
                                    img { max-width: 100%; height: auto; border-radius: 8px; margin: 16px 0; }
                                </style>
                            </head>
                            <body>
                                <div id="content"></div>
                                <script>
                                    const markdown = `\(escapedContent)`;
                                    document.getElementById('content').innerHTML = marked.parse(markdown);
                                </script>
                            </body>
                            </html>
                            """
                            
                            DispatchQueue.main.async {
                                self.singleFileWebView.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
                                DebugLogger.shared.log("✅ Markdown rendered for \(url.lastPathComponent)")
                                NSLog("✅ PeekX: Markdown rendered for \(url.lastPathComponent)")
                            }
                        }
                        
                        handler(nil)
                    }
                    return
                }

                let start = CFAbsoluteTimeGetCurrent()
                let contents = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                DebugLogger.shared.log("Enumerated \(contents.count) entries for \(url.lastPathComponent) in \(String(format: "%.1f", elapsed)) ms")
                
                let sortedContents = self.sortURLs(contents)
                var rootItems: [FileItem] = []
                var totalSize: Int64 = 0
                var folderCount = 0
                var fileCount = 0
                
                for entry in sortedContents.prefix(500) {
                    let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey, .contentModificationDateKey])
                    let item = FileItem(url: entry, resourceValues: values)
                    if item.isFolder {
                        folderCount += 1
                    } else {
                        fileCount += 1
                        totalSize += item.size
                    }
                    rootItems.append(item)
                }
                self.sortFileItems(&rootItems)
                
                let infoText = "\(self.byteFormatter.string(fromByteCount: totalSize)) · \(folderCount) folders, \(fileCount) files"
                
                DispatchQueue.main.async {
                    self.applySingleFileLayout(false)
                    let icon = NSWorkspace.shared.icon(forFile: url.path)
                    icon.size = NSSize(width: 48, height: 48)
                    DebugLogger.shared.log("Applying preview data for \(url.lastPathComponent). Diagnostics log: \(DebugLogger.shared.locationDescription())")
                    self.rootItems = rootItems
                    self.previewRootURL = url
                    self.rebuildVisibleRootItems()
                    self.iconImageView.image = icon
                    self.titleLabel.stringValue = url.lastPathComponent
                    self.infoLabel.stringValue = infoText
                    self.outlineView.reloadData()
                    self.syncPreviewWithSelection()
                    handler(nil)
                }
            } catch {
                DebugLogger.shared.log("Failed to build preview for \(url.lastPathComponent): \(error.localizedDescription)")
                DispatchQueue.main.async {
                    handler(error)
                }
            }
        }
    }
    
    // MARK: - Actions
    @objc private func filterChanged(_ sender: NSSegmentedControl) {
        guard let type = FilterType(rawValue: sender.selectedSegment) else { return }
        
        // Early return if filter hasn't changed - avoid unnecessary work
        guard type != filterType else { return }
        
        DebugLogger.shared.log("Filter switched to \(type)")
        filterType = type
        rebuildVisibleRootItems()
        
        // Use targeted reload instead of full reloadData() - significantly faster
        // This reloads only the root level items rather than the entire table structure
        outlineView.reloadItem(nil, reloadChildren: true)
        
        syncPreviewWithSelection()
    }
    
    // MARK: - Helpers
    private func sortURLs(_ urls: [URL]) -> [URL] {
        let sorted = urls.sorted { lhs, rhs in
            let lhsDir = (try? lhs.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let rhsDir = (try? rhs.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if lhsDir != rhsDir {
                return lhsDir
            }
            return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
        }
        if let descriptor = currentSortDescriptor {
            return sorted.sorted { lhs, rhs in
                compareURLs(lhs, rhs, with: descriptor)
            }
        }
        return sorted
    }
    
    private func sortFileItems(_ items: inout [FileItem]) {
        guard !items.isEmpty else { return }
        let comparator = makeItemComparator()
        items.sort(by: comparator)
    }
    
    private func makeItemComparator() -> (FileItem, FileItem) -> Bool {
        if let descriptor = currentSortDescriptor {
            return { lhs, rhs in
                self.compareFileItems(lhs, rhs, with: descriptor)
            }
        }
        return { lhs, rhs in
            self.defaultItemComparator(lhs, rhs)
        }
    }
    
    private func compareFileItems(_ lhs: FileItem, _ rhs: FileItem, with descriptor: NSSortDescriptor) -> Bool {
        let ascending = descriptor.ascending
        switch descriptor.key ?? "name" {
        case "date":
            if lhs.modificationDate == rhs.modificationDate {
                return defaultItemComparator(lhs, rhs)
            }
            return ascending ? lhs.modificationDate < rhs.modificationDate : lhs.modificationDate > rhs.modificationDate
        case "size":
            if lhs.size == rhs.size {
                return defaultItemComparator(lhs, rhs)
            }
            return ascending ? lhs.size < rhs.size : lhs.size > rhs.size
        case "kind":
            if lhs.kindDescription == rhs.kindDescription {
                return defaultItemComparator(lhs, rhs)
            }
            return ascending ? lhs.kindDescription < rhs.kindDescription : lhs.kindDescription > rhs.kindDescription
        case "name":
            fallthrough
        default:
            if lhs.name == rhs.name {
                return defaultItemComparator(lhs, rhs)
            }
            if ascending {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            } else {
                return rhs.name.localizedStandardCompare(lhs.name) == .orderedAscending
            }
        }
    }
    
    private func defaultItemComparator(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
        if lhs.isFolder != rhs.isFolder {
            return lhs.isFolder && !rhs.isFolder
        }
        return lhs.name.localizedStandardCompare(rhs.name) != .orderedDescending
    }
    
    private func resortDescendants(from items: [FileItem]) {
        guard !items.isEmpty else { return }
        let comparator = makeItemComparator()
        resortDescendants(items, comparator: comparator)
    }
    
    private func resortDescendants(_ items: [FileItem], comparator: @escaping (FileItem, FileItem) -> Bool) {
        for item in items {
            if var children = item.children {
                children.sort(by: comparator)
                item.children = children
                resortDescendants(children, comparator: comparator)
            }
        }
    }
    
    private func compareURLs(_ lhs: URL, _ rhs: URL, with descriptor: NSSortDescriptor) -> Bool {
        let key = descriptor.key ?? "name"
        let ascending = descriptor.ascending
        switch key {
        case "name":
            return ascending ?
                lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending :
                rhs.lastPathComponent.localizedStandardCompare(lhs.lastPathComponent) == .orderedAscending
        case "date":
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return ascending ? lhsDate < rhsDate : lhsDate > rhsDate
        case "size":
            let lhsSize = Int64((try? lhs.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            let rhsSize = Int64((try? rhs.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            return ascending ? lhsSize < rhsSize : lhsSize > rhsSize
        case "kind":
            let lhsType = (try? lhs.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.localizedDescription ?? ""
            let rhsType = (try? rhs.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.localizedDescription ?? ""
            return ascending ? lhsType < rhsType : lhsType > rhsType
        default:
            return true
        }
    }
    
    private func rebuildVisibleRootItems() {
        if filterType == .all {
            visibleRootItems = rootItems
            return
        }
        visibleRootItems = filterItems(rootItems)
    }
    
    private func children(of item: FileItem?) -> [FileItem] {
        if let item {
            guard let children = item.children else { return [] }
            return filterItems(children)
        }
        return visibleRootItems
    }
    
    private func filterItems(_ items: [FileItem]) -> [FileItem] {
        items.filter { item in
            filterType.matches(item)
        }
    }
    
    // Path bar update (commented out - path bar not displayed)
    // private func updatePreviewPath(for item: FileItem?) {
    //     guard let referenceRoot = previewRootURL ?? item?.url else {
    //         pathControl.url = nil
    //         return
    //     }
    //     let target = item?.url ?? referenceRoot
    //     pathControl.url = target
    // }
    
    private func syncPreviewWithSelection() {
        // Cancel any pending preview update
        previewUpdateWorkItem?.cancel()
        
        // Minimal debounce (10ms) - just enough to prevent rapid-fire updates
        // but imperceptible to users for single clicks
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.updatePreview(for: self.selectedItems.last)
        }
        previewUpdateWorkItem = workItem
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: workItem)
    }
    
    private func updatePreview(for item: FileItem?) {
        previewImageLoadTask?.cancel()
        previewImageLoadTask = nil
        previewSpinner.stopAnimation(nil)
        
        // Batch all view updates in a single transaction for better performance
        CATransaction.begin()
        
        previewImageView.image = nil
        previewedItem = item
        
        guard let item else {
            previewTitleLabel.stringValue = "No Selection"
            previewInfoLabel.stringValue = "Select a file or folder to preview."
            previewMessageLabel.stringValue = ""
            previewMessageLabel.isHidden = true
            CATransaction.commit()
            // updatePreviewPath(for: nil)
            return
        }
        
        // Use pre-built cached info string - zero string operations on UI thread
        previewTitleLabel.stringValue = item.name
        previewInfoLabel.stringValue = item.previewInfo(sizeFormatter: byteFormatter, dateFormatter: dateFormatter)
        previewMessageLabel.isHidden = true
        
        CATransaction.commit()
        // updatePreviewPath(for: item)
        
        // Use cached type checks instead of repeated UTType conformance checks
        if item.isImage {
            webView.isHidden = true
            previewImageView.isHidden = false
            loadPreviewImage(for: item)
        } else if item.isText {
            previewImageView.isHidden = true
            webView.isHidden = false
            previewMessageLabel.isHidden = true
            loadMarkdownPreview(for: item)
        } else {
            webView.isHidden = true
            previewImageView.isHidden = false
            loadLargeIcon(for: item) { [weak self] icon in
                guard let self, self.previewedItem === item else { return }
                self.previewImageView.image = icon
            }
            previewMessageLabel.stringValue = "Preview available for images and markdown only."
            previewMessageLabel.isHidden = false
        }
    }

    private func applySingleFileLayout(_ enabled: Bool) {
        singleFileMode = enabled
        mainStack.isHidden = enabled
        singleFileWebView.isHidden = !enabled
    }
    
    private func loadMarkdownPreview(for item: FileItem) {
        DispatchQueue.global(qos: .userInitiated).async {
            let text = (try? String(contentsOf: item.url, encoding: .utf8)) ?? ""
            let htmlBody = self.makeHTML(fromMarkdown: text)
            let template = """
            <html>
            <head>
            <meta charset="utf-8">
            <style>
                :root { color-scheme: light dark; }
                body {
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    margin: 0;
                    padding: 24px 28px;
                    line-height: 1.5;
                    background: transparent;
                    color: #1f1f1f;
                }
                @media (prefers-color-scheme: dark) {
                    body { color: #e5e5e5; }
                }
                h1, h2, h3, h4, h5, h6 { font-weight: 600; }
                pre, code {
                    font-family: Menlo, SFMono-Regular, Consolas, monospace;
                }
                pre {
                    background-color: rgba(142,142,147,0.08);
                    padding: 12px 16px;
                    border-radius: 8px;
                    overflow-x: auto;
                }
                table {
                    border-collapse: collapse;
                    width: 100%;
                    margin: 16px 0;
                }
                th, td {
                    border: 1px solid rgba(142,142,147,0.3);
                    padding: 6px 8px;
                    text-align: left;
                }
                blockquote {
                    border-left: 3px solid rgba(142,142,147,0.4);
                    margin: 0;
                    padding-left: 12px;
                    color: rgba(60,60,67,0.7);
                }
            </style>
            </head>
            <body>
            \(htmlBody)
            </body>
            </html>
            """
            DispatchQueue.main.async {
                guard self.previewedItem === item else { return }
                self.webView.loadHTMLString(template, baseURL: item.url.deletingLastPathComponent())
            }
        }
    }
    
    private func makeHTML(fromMarkdown markdown: String) -> String {
        if markdown.isEmpty {
            return "<p>No content.</p>"
        }
        if #available(macOS 12.0, *) {
            if let attributed = try? AttributedString(markdown: markdown) {
                let nsAttr = NSAttributedString(attributed)
                if let data = try? nsAttr.data(
                    from: NSRange(location: 0, length: nsAttr.length),
                    documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
                ), let rawHTML = String(data: data, encoding: .utf8) {
                    return extractBody(from: rawHTML)
                }
            }
        }
        let escaped = markdown
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<pre>\(escaped)</pre>"
    }
    
    private func extractBody(from html: String) -> String {
        guard let bodyStartRange = html.range(of: "<body", options: .caseInsensitive),
              let closingBracket = html[bodyStartRange.lowerBound...].firstIndex(of: ">"),
              let bodyEndRange = html.range(of: "</body>", options: .caseInsensitive) else {
            return html
        }
        let start = html.index(after: closingBracket)
        return String(html[start..<bodyEndRange.lowerBound])
    }
    
    private func loadPreviewImage(for item: FileItem) {
        previewSpinner.startAnimation(nil)
        let start = CFAbsoluteTimeGetCurrent()
        let fileURL = item.url as NSURL
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let source = CGImageSourceCreateWithURL(fileURL, nil)
            let cgImage = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            DispatchQueue.main.async {
                guard self.previewedItem === item else { return }
                self.previewSpinner.stopAnimation(nil)
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                DebugLogger.shared.log("Preview image load for \(item.name) finished in \(String(format: "%.1f", elapsed)) ms")
                if let cgImage {
                    let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    self.previewImageView.image = image
                } else {
                    self.previewMessageLabel.stringValue = "Could not load image."
                    self.previewMessageLabel.isHidden = false
                    self.loadLargeIcon(for: item) { [weak self] icon in
                        guard let self, self.previewedItem === item else { return }
                        self.previewImageView.image = icon
                    }
                }
                self.previewImageLoadTask = nil
            }
        }
        previewImageLoadTask = task
        DispatchQueue.global(qos: .userInitiated).async(execute: task)
    }
    
    private var selectedItems: [FileItem] {
        outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileItem }
    }
    
    private func actionURLs() -> [URL] {
        let selection = selectedItems.map { $0.url }
        if !selection.isEmpty { return selection }
        if let previewedItem {
            return [previewedItem.url]
        }
        return []
    }
    
    @objc private func copyPathAction() {
        let urls = actionURLs().map { $0.path }
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSString])
    }
    
    private func showQuickLook() {
        guard QLPreviewPanel.shared()?.isVisible == false else {
            QLPreviewPanel.shared()?.reloadData()
            return
        }
        guard let panel = QLPreviewPanel.shared(), !selectedItems.isEmpty else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(self)
    }
    
    private lazy var contextMenu: NSMenu = {
        let menu = NSMenu(title: "Actions")
        menu.addItem(withTitle: "Copy Path", action: #selector(copyPathAction), keyEquivalent: "")
        return menu
    }()
    
    
    private func loadChildren(for item: FileItem, completion: @escaping () -> Void) {
        if item.childrenLoaded {
            completion()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let start = CFAbsoluteTimeGetCurrent()
                let contents = try FileManager.default.contentsOfDirectory(
                    at: item.url,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
                let sorted = self.sortURLs(contents)
                var children: [FileItem] = []
                for entry in sorted.prefix(500) {
                    let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey, .contentModificationDateKey])
                    children.append(FileItem(url: entry, resourceValues: values, parent: item))
                }
                self.sortFileItems(&children)
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                DispatchQueue.main.async {
                    DebugLogger.shared.log("Loaded \(children.count) children for \(item.name) in \(String(format: "%.1f", elapsed)) ms")
                    item.setChildren(children)
                    completion()
                }
            } catch {
                DispatchQueue.main.async {
                    DebugLogger.shared.log("Failed to load children for \(item.name): \(error.localizedDescription)")
                    item.setChildren([])
                    completion()
                }
            }
        }
    }
    
    private func loadIcon(for item: FileItem, completion: @escaping (NSImage) -> Void) {
        // First check if item already has icon cached
        if let icon = item.icon {
            completion(icon)
            return
        }
        
        let path = item.url.path
        let cacheKey = path as NSString
        
        // Check NSCache
        if let cached = iconCache.object(forKey: cacheKey) {
            item.icon = cached
            completion(cached)
            return
        }
        
        // Load icon on background thread to avoid blocking UI
        iconLoadQueue.async { [weak self] in
            guard let self = self else { return }
            
            // NSWorkspace.shared.icon is thread-safe and can be called from background
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 16, height: 16)
            
            // Cache the icon
            self.iconCache.setObject(icon, forKey: cacheKey)
            item.icon = icon
            
            // Update UI on main thread
            DispatchQueue.main.async {
                completion(icon)
            }
        }
    }
    
    private func loadLargeIcon(for item: FileItem, completion: @escaping (NSImage) -> Void) {
        let path = item.url.path
        let cacheKey = "\(path)-large" as NSString
        
        // Check cache for large icon
        if let cached = iconCache.object(forKey: cacheKey) {
            completion(cached)
            return
        }
        
        // Load large icon on background thread
        iconLoadQueue.async { [weak self] in
            guard let self = self else { return }
            
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 256, height: 256)
            
            // Cache the large icon
            self.iconCache.setObject(icon, forKey: cacheKey)
            
            // Update UI on main thread
            DispatchQueue.main.async {
                completion(icon)
            }
        }
    }
}

// MARK: - NSOutlineViewDataSource
extension PreviewViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        return children(of: item as? FileItem).count
    }
    
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        return children(of: item as? FileItem)[index]
    }
    
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let fileItem = item as? FileItem else { return false }
        return fileItem.isFolder
    }
}

// MARK: - NSOutlineViewDelegate
extension PreviewViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let fileItem = item as? FileItem,
              let identifier = tableColumn?.identifier else { return nil }
        let reuseIdentifier = NSUserInterfaceItemIdentifier("cell-\(identifier.rawValue)")
        let cellView: NSTableCellView
        
        if let existing = outlineView.makeView(withIdentifier: reuseIdentifier, owner: self) as? NSTableCellView {
            cellView = existing
        } else {
            cellView = NSTableCellView()
            cellView.identifier = reuseIdentifier
            let stackView = NSStackView()
            stackView.translatesAutoresizingMaskIntoConstraints = false
            stackView.orientation = .horizontal
            stackView.alignment = .centerY
            stackView.spacing = 6
            cellView.addSubview(stackView)
            NSLayoutConstraint.activate([
                stackView.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 6),
                stackView.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -6),
                stackView.topAnchor.constraint(equalTo: cellView.topAnchor, constant: 2),
                stackView.bottomAnchor.constraint(equalTo: cellView.bottomAnchor, constant: -2)
            ])
            if identifier.rawValue == "name" {
                let imageView = NSImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.imageScaling = .scaleProportionallyDown
                NSLayoutConstraint.activate([
                    imageView.widthAnchor.constraint(equalToConstant: 16),
                    imageView.heightAnchor.constraint(equalToConstant: 16)
                ])
                stackView.addArrangedSubview(imageView)
                cellView.imageView = imageView
            }
            let alignment: NSTextAlignment = identifier.rawValue == "size" ? .right : .left
            let textField = NSTextField()
            textField.isBordered = false
            textField.backgroundColor = .clear
            textField.isEditable = false
            textField.font = NSFont.systemFont(ofSize: 13)
            textField.textColor = .labelColor
            textField.lineBreakMode = .byTruncatingTail
            textField.alignment = alignment
            textField.translatesAutoresizingMaskIntoConstraints = false
            stackView.addArrangedSubview(textField)
            cellView.textField = textField
        }
        
        switch identifier.rawValue {
        case "name":
            cellView.textField?.stringValue = fileItem.name
            loadIcon(for: fileItem) { icon in
                cellView.imageView?.image = icon
            }
        case "date":
            // Use cached formatted date to avoid repeated formatting
            cellView.textField?.stringValue = fileItem.formattedDate(using: dateFormatter)
        case "size":
            // Use cached formatted size to avoid repeated formatting
            cellView.textField?.stringValue = fileItem.formattedSize(using: byteFormatter)
        case "kind":
            cellView.textField?.stringValue = fileItem.kindDescription
        default:
            cellView.textField?.stringValue = ""
        }
        return cellView
    }
    
    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        currentSortDescriptor = outlineView.sortDescriptors.first
        
        // Move sorting to background thread to avoid blocking UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            self.sortFileItems(&self.rootItems)
            self.resortDescendants(from: self.rootItems)
            
            DispatchQueue.main.async {
                self.rebuildVisibleRootItems()
                // Use targeted reload instead of full reloadData()
                self.outlineView.reloadItem(nil, reloadChildren: true)
            }
        }
    }
    
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let fileItem = item as? FileItem else { return false }
        loadChildren(for: fileItem) {
            outlineView.reloadItem(fileItem, reloadChildren: true)
        }
        return true
    }
    
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSOutlineView === outlineView else { return }
        // Removed logging here to reduce overhead on every selection change
        syncPreviewWithSelection()
    }
}

// MARK: - Keyboard & Menu Handling
extension PreviewViewController {
}

extension PreviewViewController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        let location = outlineView.convert(outlineView.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        let row = outlineView.row(at: location)
        if row >= 0 && !outlineView.isRowSelected(row) {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let hasSelection = !selectedItems.isEmpty
        menu.items.forEach { $0.isEnabled = hasSelection }
    }
}

// MARK: - Quick Look Panel
extension PreviewViewController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedItems.count
    }
    
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        selectedItems[index]
    }
}

// MARK: - Outline Keyboard Delegate
extension PreviewViewController: FinderOutlineViewKeyboardDelegate {
    func outlineView(_ outlineView: FinderOutlineView, handle event: NSEvent) -> Bool {
        let commandPressed = event.modifierFlags.contains(.command)
        switch (event.keyCode, commandPressed) {
        case (49, false): // Space
            showQuickLook()
            return true
        case (_, true) where event.charactersIgnoringModifiers == "c":
            copyPathAction()
            return true
        default:
            return false
        }
    }
}
