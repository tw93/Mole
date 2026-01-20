//
//  DiskMapView.swift
//  Tonic
//
//  Visual disk map visualization with treemap-style layout
//  Task ID: fn-1.21
//

import SwiftUI

// MARK: - File Type Categories

enum FileTypeCategory: String, CaseIterable {
    case images = "Images"
    case videos = "Videos"
    case audio = "Audio"
    case documents = "Documents"
    case code = "Code"
    case archives = "Archives"
    case system = "System"
    case other = "Other"

    var icon: String {
        switch self {
        case .images: return "photo"
        case .videos: return "video"
        case .audio: return "music.note"
        case .documents: return "doc"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .archives: return "archivebox"
        case .system: return "gear"
        case .other: return "doc"
        }
    }

    var color: Color {
        switch self {
        case .images: return Color(red: 0.3, green: 0.6, blue: 1.0)
        case .videos: return Color(red: 0.8, green: 0.3, blue: 0.5)
        case .audio: return Color(red: 1.0, green: 0.6, blue: 0.0)
        case .documents: return Color(red: 0.4, green: 0.5, blue: 0.6)
        case .code: return Color(red: 0.3, green: 0.7, blue: 0.4)
        case .archives: return Color(red: 0.6, green: 0.5, blue: 0.3)
        case .system: return Color(red: 0.5, green: 0.5, blue: 0.5)
        case .other: return Color(red: 0.6, green: 0.4, blue: 0.6)
        }
    }

    static func from(extension ext: String) -> FileTypeCategory {
        let imageExts = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "webp", "heic", "ico", "svg"]
        let videoExts = ["mp4", "mov", "avi", "mkv", "flv", "wmv", "webm", "m4v"]
        let audioExts = ["mp3", "m4a", "wav", "flac", "aac", "ogg", "wma"]
        let documentExts = ["pdf", "doc", "docx", "txt", "rtf", "pages", "xls", "xlsx", "ppt", "pptx"]
        let codeExts = ["swift", "m", "h", "cpp", "c", "js", "jsx", "ts", "tsx", "py", "go", "rs", "java", "kt", "json", "xml", "yaml", "yml"]
        let archiveExts = ["zip", "rar", "7z", "tar", "gz", "bz2", "dmg", "pkg"]

        let lowerExt = ext.lowercased()

        if imageExts.contains(lowerExt) { return .images }
        if videoExts.contains(lowerExt) { return .videos }
        if audioExts.contains(lowerExt) { return .audio }
        if documentExts.contains(lowerExt) { return .documents }
        if codeExts.contains(lowerExt) { return .code }
        if archiveExts.contains(lowerExt) { return .archives }

        return .other
    }
}

// MARK: - Treemap Node

struct TreemapNode: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let path: String
    let size: Int64
    let category: FileTypeCategory
    var children: [TreemapNode] = []
    let depth: Int

    var color: Color {
        category.color
    }

    var hasChildren: Bool {
        !children.isEmpty
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    static func leaf(name: String, path: String, size: Int64, category: FileTypeCategory) -> TreemapNode {
        TreemapNode(name: name, path: path, size: size, category: category, children: [], depth: 0)
    }

    static func directory(name: String, path: String, children: [TreemapNode], depth: Int = 0) -> TreemapNode {
        let totalSize = children.reduce(0) { $0 + $1.size }
        // Find dominant category
        let categoryBySize = Dictionary(grouping: children, by: { $0.category })
            .mapValues { nodes in nodes.reduce(0) { $0 + $1.size } }
            .max { $0.value < $1.value }?.key ?? .other

        return TreemapNode(name: name, path: path, size: totalSize, category: categoryBySize, children: children, depth: depth)
    }
}

// MARK: - Treemap Rectangle

struct TreemapRect: Identifiable {
    let id: UUID
    let node: TreemapNode
    let frame: CGRect

    init(node: TreemapNode, frame: CGRect) {
        self.id = node.id
        self.node = node
        self.frame = frame
    }
}

// MARK: - Disk Map View

struct DiskMapView: View {
    @State private var scanner = DiskMapScanner()
    @State private var rootNode: TreemapNode?
    @State private var visibleNodes: [TreemapRect] = []
    @State private var currentPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var navigationPath: [String] = []
    @State private var isScanning = false
    @State private var hoveredNode: TreemapNode?
    @State private var selectedNode: TreemapNode?
    @State private var animationAmount: CGFloat = 0
    @State private var showLegend = true

    private let homePath = FileManager.default.homeDirectoryForCurrentUser.path

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            mainContent
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await initialScan()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            // Navigation
            HStack(spacing: 4) {
                Button {
                    navigateBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(navigationPath.isEmpty)

                Button {
                    Task { await refreshScan() }
                } label: {
                    Image(systemName: isScanning ? "stop.circle.fill" : "arrow.clockwise")
                }
                .disabled(isScanning)
            }
            .buttonStyle(.borderless)

            // Current path
            Text(displayPath)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer()

            // View toggle
            Button {
                withAnimation {
                    showLegend.toggle()
                }
            } label: {
                Image(systemName: "list.bullet")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        HStack(spacing: 0) {
            // Treemap view
            VStack(spacing: 0) {
                if isScanning {
                    scanningView
                } else if let root = rootNode {
                    treemapView(for: root)
                } else {
                    initialView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Legend sidebar
            if showLegend {
                Divider()

                legendSidebar
                    .frame(width: 200)
            }
        }
    }

    // MARK: - Initial View

    private var initialView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 48))
                .foregroundStyle(
                    LinearGradient(
                        colors: [FileTypeCategory.images.color, FileTypeCategory.videos.color, FileTypeCategory.code.color],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("Disk Map")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Visualize disk usage with an interactive treemap")
                .foregroundColor(.secondary)

            Button("Scan Current Directory") {
                Task { await scanCurrentPath() }
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Scanning View

    private var scanningView: some View {
        VStack(spacing: 16) {
            Spacer()

            ProgressView()
                .scaleEffect(1.5)

            Text("Scanning directory...")
                .font(.headline)

            Text(currentPath)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 400)

            Spacer()
        }
    }

    // MARK: - Treemap View

    private func treemapView(for root: TreemapNode) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                // Background
                Color(nsColor: .textBackgroundColor)

                // Treemap blocks
                ForEach(visibleNodes) { nodeRect in
                    treemapBlock(nodeRect)
                        .position(
                            x: nodeRect.frame.midX,
                            y: nodeRect.frame.midY
                        )
                }

                // Hover tooltip
                if let hovered = hoveredNode {
                    hoverTooltip(for: hovered)
                        .position(
                            x: min(max(geometry.size.width / 2, 100), geometry.size.width - 100),
                            y: 80
                        )
                }
            }
            .onTapGesture {
                selectedNode = nil
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let selected = selectedNode {
                detailBar(for: selected)
            }
        }
        .onChange(of: rootNode) { _, newRoot in
            if let root = newRoot {
                calculateLayout(for: root, in: CGSize(width: 800, height: 600))
            }
        }
    }

    private func treemapBlock(_ nodeRect: TreemapRect) -> some View {
        let node = nodeRect.node
        let frame = nodeRect.frame
        let isHovered = hoveredNode?.id == node.id
        let isSelected = selectedNode?.id == node.id

        return ZStack(alignment: .leading) {
            // Main rectangle
            RoundedRectangle(cornerRadius: node.hasChildren ? 4 : 2)
                .fill(node.color.opacity(isHovered ? 0.8 : (isSelected ? 0.6 : 0.5)))
                .overlay(
                    RoundedRectangle(cornerRadius: node.hasChildren ? 4 : 2)
                        .stroke(isSelected ? Color.white : Color.clear, lineWidth: 2)
                )

            // Label (only if large enough)
            if frame.width > 40 && frame.height > 20 {
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                        .font(.system(size: min(12, frame.width / 8), weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.3), radius: 1)

                    if frame.height > 35 {
                        Text(node.formattedSize)
                            .font(.system(size: min(10, frame.width / 10)))
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.3), radius: 1)
                    }
                }
                .padding(4)
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredNode = hovering ? node : nil
            }
        }
        .onTapGesture {
            if node.hasChildren {
                navigateTo(node)
            }
            selectedNode = node
        }
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
    }

    private func hoverTooltip(for node: TreemapNode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: node.category.icon)
                    .foregroundColor(node.category.color)

                Text(node.name)
                    .font(.headline)
            }

            Divider()

            HStack {
                Text("Size:")
                    .foregroundColor(.secondary)
                Text(node.formattedSize)
                    .fontWeight(.medium)
            }

            HStack {
                Text("Type:")
                    .foregroundColor(.secondary)
                Text(node.category.rawValue)
                    .fontWeight(.medium)
            }

            HStack {
                Text("Path:")
                    .foregroundColor(.secondary)
                Text((node.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .lineLimit(2)
                    .frame(maxWidth: 200, alignment: .leading)
            }

            if node.hasChildren {
                Text("\(node.children.count) items")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
                .shadow(radius: 10)
        )
        .frame(maxWidth: 280)
    }

    private func detailBar(for node: TreemapNode) -> some View {
        HStack(spacing: 16) {
            // Icon
            Image(systemName: node.hasChildren ? "folder.fill" : "doc.fill")
                .font(.title2)
                .foregroundColor(node.color)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(.headline)

                Text((node.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Size
            VStack(alignment: .trailing, spacing: 2) {
                Text(node.formattedSize)
                    .font(.headline)

                Text(node.category.rawValue)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Actions
            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")

                if node.hasChildren {
                    Button {
                        navigateTo(node)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .help("Open folder")
                }
            }
        }
        .padding()
        .background(.regularMaterial)
    }

    // MARK: - Legend Sidebar

    private var legendSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("File Types")
                    .font(.headline)
                    .padding(.horizontal)
                    .padding(.top)

                ForEach(FileTypeCategory.allCases, id: \.self) { category in
                    legendItem(category)
                }

                Divider()
                    .padding(.vertical, 8)

                // Statistics
                if let root = rootNode {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Statistics")
                            .font(.headline)
                            .padding(.horizontal)

                        statItem("Total Size", root.formattedSize)
                        statItem("Items", "\(countItems(root))")
                        statItem("Depth", "\(maxDepth(root))")
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.bottom)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func legendItem(_ category: FileTypeCategory) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(category.color)
                .frame(width: 16, height: 16)

            Text(category.rawValue)
                .font(.body)

            Spacer()
        }
        .padding(.horizontal)
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private func statItem(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
        .font(.caption)
    }

    // MARK: - Navigation

    private var displayPath: String {
        if currentPath == homePath {
            return "~"
        }
        return currentPath.replacingOccurrences(of: homePath, with: "~")
    }

    private func navigateBack() {
        guard !navigationPath.isEmpty else { return }
        currentPath = navigationPath.removeLast()
        Task { await scanCurrentPath() }
    }

    private func navigateTo(_ node: TreemapNode) {
        navigationPath.append(currentPath)
        currentPath = node.path
        Task { await scanCurrentPath() }
    }

    // MARK: - Scanning

    private func initialScan() async {
        await scanCurrentPath()
    }

    private func scanCurrentPath() async {
        isScanning = true
        selectedNode = nil
        hoveredNode = nil

        let node = await scanner.scanPath(currentPath)
        rootNode = node

        // Trigger layout calculation
        if let root = rootNode {
            calculateLayout(for: root, in: CGSize(width: 800, height: 600))
        }

        isScanning = false
    }

    private func refreshScan() async {
        await scanCurrentPath()
    }

    // MARK: - Layout Calculation

    private func calculateLayout(for node: TreemapNode, in size: CGSize) {
        var rects: [TreemapRect] = []

        if node.hasChildren {
            let childRects = squarifyLayout(
                nodes: node.children,
                in: CGRect(origin: .zero, size: size)
            )
            rects.append(contentsOf: childRects)
        } else {
            rects.append(TreemapRect(node: node, frame: CGRect(origin: .zero, size: size)))
        }

        withAnimation(.easeInOut(duration: 0.3)) {
            visibleNodes = rects
        }
    }

    // MARK: - Squarified Treemap Algorithm

    private func squarifyLayout(nodes: [TreemapNode], in rect: CGRect) -> [TreemapRect] {
        guard !nodes.isEmpty else { return [] }

        var sortedNodes = nodes.sorted { $0.size > $1.size }
        let totalSize = sortedNodes.reduce(0) { $0 + $1.size }
        var result: [TreemapRect] = []
        var currentRect = rect

        while !sortedNodes.isEmpty {
            let (row, remaining) = extractRow(from: &sortedNodes, remaining: totalSize, in: currentRect)
            let rowRects = layoutRow(row, in: currentRect)
            result.append(contentsOf: rowRects)

            // Update remaining rectangle
            if let lastRowRect = rowRects.last {
                let rowTotalSize = row.reduce(0) { $0 + $1.size }
                let splitRatio = Double(rowTotalSize) / Double(totalSize)

                if currentRect.width > currentRect.height {
                    let newWidth = currentRect.width * (1 - splitRatio)
                    currentRect = CGRect(
                        x: currentRect.maxX - newWidth,
                        y: currentRect.minY,
                        width: newWidth,
                        height: currentRect.height
                    )
                } else {
                    let newHeight = currentRect.height * (1 - splitRatio)
                    currentRect = CGRect(
                        x: currentRect.minX,
                        y: currentRect.maxY - newHeight,
                        width: currentRect.width,
                        height: newHeight
                    )
                }
            }
        }

        return result
    }

    private func extractRow(from nodes: inout [TreemapNode], remaining: Int64, in rect: CGRect) -> ([TreemapNode], [TreemapNode]) {
        guard !nodes.isEmpty else { return ([], []) }

        var row: [TreemapNode] = []
        var rowSize: Int64 = 0
        let first = nodes.first!

        // Calculate worst ratio for current row
        func worstRatio() -> Double {
            guard !row.isEmpty else { return Double.greatestFiniteMagnitude }

            var min: Double = .infinity
            var max: Double = 0

            for node in row {
                let size = Double(node.size)
                min = Swift.min(min, size)
                max = Swift.max(max, size)
            }

            let rectMin = Swift.min(Double(rect.width), Double(rect.height))
            let rectMax = Swift.max(Double(rect.width), Double(rect.height))

            let rowTotal = Double(rowSize)
            return Swift.max(
                (rectMin * rectMin * max) / (rowTotal * rowTotal),
                (rowTotal * rowTotal) / (rectMax * rectMax * min)
            )
        }

        row.append(first)
        rowSize += first.size
        nodes.removeFirst()

        while !nodes.isEmpty {
            let next = nodes.first!
            let testRow = row + [next]
            let testRowSize = rowSize + next.size

            var testMin: Double = .infinity
            var testMax: Double = 0

            for node in testRow {
                let size = Double(node.size)
                testMin = Swift.min(testMin, size)
                testMax = Swift.max(testMax, size)
            }

            let rectMin = Swift.min(Double(rect.width), Double(rect.height))
            let rectMax = Swift.max(Double(rect.width), Double(rect.height))

            let newRatio = Swift.max(
                (rectMin * rectMin * testMax) / (Double(testRowSize) * Double(testRowSize)),
                (Double(testRowSize) * Double(testRowSize)) / (rectMax * rectMax * testMin)
            )

            if newRatio > worstRatio() {
                break
            }

            row.append(next)
            rowSize = testRowSize
            nodes.removeFirst()
        }

        return (row, nodes)
    }

    private func layoutRow(_ row: [TreemapNode], in rect: CGRect) -> [TreemapRect] {
        let totalSize = row.reduce(0) { $0 + $1.size }
        var result: [TreemapRect] = []
        var currentOrigin = rect.origin

        let isHorizontal = rect.width >= rect.height

        for node in row {
            let size = Double(node.size)
            let fraction = size / Double(totalSize)

            let nodeRect: CGRect
            if isHorizontal {
                let width = rect.width * fraction
                nodeRect = CGRect(
                    x: currentOrigin.x,
                    y: currentOrigin.y,
                    width: width,
                    height: rect.height
                )
                currentOrigin.x += width
            } else {
                let height = rect.height * fraction
                nodeRect = CGRect(
                    x: currentOrigin.x,
                    y: currentOrigin.y,
                    width: rect.width,
                    height: height
                )
                currentOrigin.y += height
            }

            result.append(TreemapRect(node: node, frame: nodeRect))
        }

        return result
    }

    // MARK: - Utility

    private func countItems(_ node: TreemapNode) -> Int {
        if node.hasChildren {
            return node.children.reduce(0) { $0 + countItems($1) }
        }
        return 1
    }

    private func maxDepth(_ node: TreemapNode) -> Int {
        guard node.hasChildren else { return 0 }
        let childDepths = node.children.map { maxDepth($0) }
        return 1 + (childDepths.max() ?? 0)
    }
}

// MARK: - Disk Map Scanner

@Observable
final class DiskMapScanner {
    private let fileManager = FileManager.default
    private var scanTask: Task<Void, Never>?

    /// Cancel the current scan
    func cancelScan() {
        scanTask?.cancel()
    }

    func scanPath(_ path: String) async -> TreemapNode {
        // Create a timeout wrapper
        return await withTimeout(seconds: 30) {
            await self.performScan(path)
        }
    }

    private func performScan(_ path: String) async -> TreemapNode {
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return TreemapNode.leaf(name: "Error", path: path, size: 0, category: .other)
        }

        let name = (path as NSString).lastPathComponent

        if isDirectory.boolValue {
            let children = await scanDirectory(path)
            return TreemapNode.directory(name: name, path: path, children: children)
        } else {
            let size = getFileSize(path)
            let ext = (path as NSString).pathExtension
            let category = FileTypeCategory.from(extension: ext)
            return TreemapNode.leaf(name: name, path: path, size: size, category: category)
        }
    }

    private func scanDirectory(_ path: String) async -> [TreemapNode] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var nodes: [TreemapNode] = []
        let maxSize = 50 // Reduced from 100 for better performance

        for (index, item) in contents.enumerated() where index < maxSize {
            // Check for cancellation
            if Task.isCancelled {
                break
            }

            let itemPath = item.path
            let name = (itemPath as NSString).lastPathComponent
            var isDirectory: ObjCBool = false

            guard fileManager.fileExists(atPath: itemPath, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                // Only scan top level for directories (don't recurse)
                let size = getDirectorySizeFast(itemPath)
                if size > 0 {
                    nodes.append(TreemapNode.directory(
                        name: name,
                        path: itemPath,
                        children: [],
                        depth: 1
                    ))
                    // Override the size calculated by directory
                    if let lastIndex = nodes.indices.last {
                        nodes[lastIndex] = TreemapNode(
                            name: name,
                            path: itemPath,
                            size: size,
                            category: .system,
                            children: [],
                            depth: 1
                        )
                    }
                }
            } else {
                let size = getFileSize(itemPath)
                let ext = (itemPath as NSString).pathExtension
                let category = FileTypeCategory.from(extension: ext)
                nodes.append(TreemapNode.leaf(name: name, path: itemPath, size: size, category: category))
            }
        }

        // Sort by size and limit to top items
        return nodes.sorted { $0.size > $1.size }.prefix(30).map { $0 }
    }

    private func getFileSize(_ path: String) -> Int64 {
        return (try? fileManager.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
    }

    private func getDirectorySizeFast(_ path: String) -> Int64 {
        // Use a simple estimate without full recursion
        if let attrs = try? fileManager.attributesOfItem(atPath: path),
           let fileType = attrs[.type] as? FileAttributeType,
           fileType == .typeDirectory {
            // Return a placeholder size - will be calculated on-demand
            return 1024 * 1024 // 1 MB placeholder
        }
        return 0
    }

    /// Execute operation with timeout
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async -> T) async -> T {
        let task = Task {
            await operation()
        }

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            task.cancel()
        }

        let result = await task.value
        timeoutTask.cancel()
        return result
    }
}

// MARK: - Preview

#Preview {
    DiskMapView()
        .frame(width: 900, height: 600)
}
