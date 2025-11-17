// PeekX - Folder Preview Extension for macOS
// Copyright © 2025. All rights reserved.

import Cocoa
import Quartz
import UniformTypeIdentifiers
import QuickLook

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
        isFolder ? "Folder" : (contentType?.localizedDescription ?? "File")
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
                return item.contentType?.conforms(to: .image) ?? false
            case .documents:
                if item.isFolder { return false }
                if let type = item.contentType {
                    if type.conforms(to: .image) || type.conforms(to: .audiovisualContent) { return false }
                }
                return true
            case .media:
                return item.contentType?.conforms(to: .audiovisualContent) ?? false
            }
        }
    }
    
    // MARK: - UI Components
    
    private var scrollView: NSScrollView!
    private var splitView: NSSplitView!
    private var outlineView: FinderOutlineView!
    private var headerView: NSView!
    private var iconImageView: NSImageView!
    private var titleLabel: NSTextField!
    private var infoLabel: NSTextField!
    private var filterControl: NSSegmentedControl!
    private var previewPane: NSView!
    private var pathBarView: NSView!
    private var pathControl: NSPathControl!
    private var previewImageView: NSImageView!
    private var previewSpinner: NSProgressIndicator!
    private var previewTitleLabel: NSTextField!
    private var previewInfoLabel: NSTextField!
    private var previewMessageLabel: NSTextField!
    
    // MARK: - Data State
    
    private var rootItems: [FileItem] = []
    private var filterType: FilterType = .all
    private var currentSortDescriptor: NSSortDescriptor? = NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))
    private var visibleRootItems: [FileItem] = []
    private var previewedItem: FileItem?
    private var previewImageLoadTask: DispatchWorkItem?
    private var previewRootURL: URL?
    private var didSetInitialSplitPosition = false
    
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
        
        headerView = createHeaderView()
        let controlsStack = createControlsStack()
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
        
        pathBarView = createPathBar()
        
        container.addSubview(headerView)
        container.addSubview(controlsStack)
        container.addSubview(pathBarView)
        container.addSubview(splitView)
        
        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            headerView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            headerView.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            
            controlsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            controlsStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            controlsStack.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 12),
            
            pathBarView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            pathBarView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            pathBarView.topAnchor.constraint(equalTo: controlsStack.bottomAnchor, constant: 8),
            pathBarView.heightAnchor.constraint(equalToConstant: 26),
            
            splitView.topAnchor.constraint(equalTo: pathBarView.bottomAnchor, constant: 8),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            splitView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
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
        
        previewSpinner = NSProgressIndicator()
        previewSpinner.translatesAutoresizingMaskIntoConstraints = false
        previewSpinner.style = .spinning
        previewSpinner.controlSize = .large
        previewSpinner.isDisplayedWhenStopped = false
        
        imageContainer.addSubview(previewImageView)
        imageContainer.addSubview(previewSpinner)
        
        let flexibleWidth = imageContainer.widthAnchor.constraint(equalToConstant: 0)
        flexibleWidth.priority = .defaultLow
        NSLayoutConstraint.activate([
            previewImageView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
            previewImageView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
            previewImageView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
            previewImageView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),
            
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
                
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 48, height: 48)
                let infoText = "\(self.byteFormatter.string(fromByteCount: totalSize)) · \(folderCount) folders, \(fileCount) files"
                
                DispatchQueue.main.async {
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
        DebugLogger.shared.log("Filter switched to \(type)")
        filterType = type
        rebuildVisibleRootItems()
        outlineView.reloadData()
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
    
    private func updatePreviewPath(for item: FileItem?) {
        guard let referenceRoot = previewRootURL ?? item?.url else {
            pathControl.url = nil
            return
        }
        let target = item?.url ?? referenceRoot
        pathControl.url = target
    }
    
    private func syncPreviewWithSelection() {
        updatePreview(for: selectedItems.last)
    }
    
    private func updatePreview(for item: FileItem?) {
        previewImageLoadTask?.cancel()
        previewImageLoadTask = nil
        previewSpinner.stopAnimation(nil)
        previewImageView.image = nil
        previewedItem = item
        
        guard let item else {
            previewTitleLabel.stringValue = "No Selection"
            previewInfoLabel.stringValue = "Select a file or folder to preview."
            previewMessageLabel.stringValue = ""
            previewMessageLabel.isHidden = true
            updatePreviewPath(for: nil)
            return
        }
        
        previewTitleLabel.stringValue = item.name
        
        var infoSegments: [String] = []
        if !item.isFolder {
            infoSegments.append(byteFormatter.string(fromByteCount: item.size))
        }
        infoSegments.append(item.kindDescription)
        infoSegments.append(dateFormatter.string(from: item.modificationDate))
        previewInfoLabel.stringValue = infoSegments.joined(separator: " · ")
        
        previewMessageLabel.isHidden = true
        updatePreviewPath(for: item)
        
        if item.contentType?.conforms(to: .image) == true {
            DebugLogger.shared.log("Preview loading image \(item.name)")
            loadPreviewImage(for: item)
        } else {
            loadLargeIcon(for: item) { [weak self] icon in
                guard let self, self.previewedItem === item else { return }
                self.previewImageView.image = icon
            }
            previewMessageLabel.stringValue = "Preview available for images only."
            previewMessageLabel.isHidden = false
        }
    }
    
    private func loadPreviewImage(for item: FileItem) {
        previewSpinner.startAnimation(nil)
        let start = CFAbsoluteTimeGetCurrent()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            autoreleasepool {
                let image = NSImage(contentsOf: item.url)
                DispatchQueue.main.async {
                    guard self.previewedItem === item else { return }
                    self.previewSpinner.stopAnimation(nil)
                    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                    DebugLogger.shared.log("Preview image load for \(item.name) finished in \(String(format: "%.1f", elapsed)) ms")
                    if let image {
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
        if let icon = item.icon {
            completion(icon)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let icon = NSWorkspace.shared.icon(forFile: item.url.path)
            icon.size = NSSize(width: 16, height: 16)
            DispatchQueue.main.async {
                item.icon = icon
                completion(icon)
            }
        }
    }
    
    private func loadLargeIcon(for item: FileItem, completion: @escaping (NSImage) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let icon = NSWorkspace.shared.icon(forFile: item.url.path)
            icon.size = NSSize(width: 256, height: 256)
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
            cellView.textField?.stringValue = dateFormatter.string(from: fileItem.modificationDate)
        case "size":
            cellView.textField?.stringValue = fileItem.isFolder ? "—" : byteFormatter.string(fromByteCount: fileItem.size)
        case "kind":
            cellView.textField?.stringValue = fileItem.kindDescription
        default:
            cellView.textField?.stringValue = ""
        }
        return cellView
    }
    
    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        currentSortDescriptor = outlineView.sortDescriptors.first
        rebuildVisibleRootItems()
        outlineView.reloadData()
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
        DebugLogger.shared.log("Selection changed → \(selectedItems.last?.name ?? "none")")
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
