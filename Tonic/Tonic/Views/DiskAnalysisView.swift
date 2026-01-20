//
//  DiskAnalysisView.swift
//  Tonic
//
//  Disk analysis view with file browser and visualization
//

import SwiftUI

struct DiskAnalysisView: View {
    @State private var scanner = DiskScanner()
    @State private var currentPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var scanResult: DiskScanResult?
    @State private var overviewEntries: [DirectoryOverviewEntry] = []
    @State private var isScanning = false
    @State private var errorMessage: String?
    @State private var showLargeFiles = false
    @State private var selectedPath: String?
    @State private var scanProgress: DiskScanProgress?
    @State private var navigationPath: [String] = []
    @State private var permissionManager = PermissionManager.shared
    @State private var hasFullDiskAccess: Bool = false
    @State private var isCheckingPermissions: Bool = false

    private let homePath = FileManager.default.homeDirectoryForCurrentUser.path

    var body: some View {
        VStack(spacing: 0) {
            // Header with path and controls
            header

            Divider()

            // Content area
            if isCheckingPermissions {
                permissionCheckView
            } else if !hasFullDiskAccess {
                permissionRequiredView
            } else if isScanning {
                progressView
            } else if let error = errorMessage {
                errorView(error)
            } else if scanResult != nil {
                resultsView
            } else {
                initialView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await checkPermissions()
        }
    }

    // MARK: - Permission Check View

    private var permissionCheckView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.2)

            Text("Checking permissions...")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Permission Required View

    private var permissionRequiredView: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer()
                    .frame(height: 40)

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 56))
                    .foregroundColor(.orange)

                VStack(spacing: 12) {
                    Text("Full Disk Access Required")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Disk Analysis needs Full Disk Access to scan all folders and files on your Mac")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 40)

                // Benefits section
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Scan your entire home directory")
                            .font(.body)
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Access system folders and applications")
                            .font(.body)
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Find large files anywhere on your disk")
                            .font(.body)
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("No annoying permission pop-ups during scan")
                            .font(.body)
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(12)

                // Step-by-step instructions
                VStack(alignment: .leading, spacing: 16) {
                    Text("How to grant Full Disk Access:")
                        .font(.headline)
                        .foregroundColor(.primary)

                    permissionStep(number: 1, text: "Click the button below to open System Settings")
                    permissionStep(number: 2, text: "Click the lock icon and enter your Mac password")
                    permissionStep(number: 3, text: "Find \"Tonic\" in the applications list")
                    permissionStep(number: 4, text: "Toggle the switch next to Tonic to enable it")
                    permissionStep(number: 5, text: "Quit System Settings and click \"I've Granted Access\" below")
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(12)

                // Action buttons
                VStack(spacing: 12) {
                    Button {
                        grantFullDiskAccess()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "gear")
                            Text("Open System Settings")
                        }
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentColor)
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task {
                            await checkPermissions()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle")
                            Text("I've Granted Access")
                                .fontWeight(.medium)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        Task {
                            await checkPermissions()
                        }
                    } label: {
                        Text("Re-check Permissions")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)

                Spacer()
                    .frame(height: 20)
            }
            .padding()
        }
    }

    private func permissionStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.orange))

            Text(text)
                .font(.body)
                .foregroundColor(.primary)

            Spacer()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            // Navigation buttons
            HStack(spacing: 4) {
                Button {
                    navigateBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(navigationPath.isEmpty)

                Button {
                    navigateUp()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(currentPath == homePath)

                Button {
                    Task { await refreshScan() }
                } label: {
                    Image(systemName: isScanning ? "stop.circle.fill" : "arrow.clockwise")
                }
                .disabled(isScanning || !hasFullDiskAccess)
            }
            .buttonStyle(.borderless)

            // Current path
            Text(displayPath)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer()

            // Toggle views
            Picker("View", selection: $showLargeFiles) {
                Text("Directories").tag(false)
                Text("Large Files").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(isScanning)
            .frame(width: 180)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Progress View

    private var progressView: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView()
                .scaleEffect(1.5)

            if let progress = scanProgress {
                VStack(spacing: 8) {
                    Text("Scanning...")
                        .font(.headline)

                    Text(progress.currentPath)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 500)

                    HStack(spacing: 20) {
                        Label("\(progress.formattedFilesScanned) items", systemImage: "doc")
                        Label("\(progress.formattedBytesScanned)", systemImage: "externaldrive")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }

            // Cancel button
            Button("Cancel Scan") {
                scanner.cancelScan()
                isScanning = false
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Error View

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Scan Error")
                .font(.headline)

            Text(error)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // Check if it's a permission error
            if error.contains("Full Disk Access") || error.contains("permission") || error.contains("Access denied") {
                Button("Grant Permissions") {
                    grantFullDiskAccess()
                }
                .buttonStyle(.borderedProminent)
            }

            Button("Try Again") {
                Task { await refreshScan() }
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Results View

    private var resultsView: some View {
        VStack(spacing: 0) {
            // Summary bar
            if let result = scanResult {
                summaryBar(result)
            }

            Divider()

            // Entries list
            if showLargeFiles, let result = scanResult, !result.largeFiles.isEmpty {
                largeFilesList(result.largeFiles)
            } else if let result = scanResult {
                entriesList(result.entries)
            }
        }
    }

    private func summaryBar(_ result: DiskScanResult) -> some View {
        HStack(spacing: 20) {
            Label(result.formattedTotalSize, systemImage: "externaldrive.fill")
                .foregroundColor(.primary)

            Label("\(result.formattedFileCount) items", systemImage: "doc.fill")

            Spacer()

            Text(String(format: "%.1fs", result.scanDuration))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func entriesList(_ entries: [DirEntry]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    EntryRow(entry: entry, isSelected: selectedPath == entry.path) {
                        selectedPath = entry.path
                        if entry.isDir {
                            navigateTo(entry.path)
                        }
                    }
                }
            }
        }
    }

    private func largeFilesList(_ files: [LargeFile]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(files) { file in
                    LargeFileRow(file: file, isSelected: selectedPath == file.path) {
                        selectedPath = file.path
                        // Open in Finder
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                    }
                }
            }
        }
    }

    // MARK: - Initial View

    private var initialView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "externaldrive.fill")
                .font(.system(size: 48))
                .foregroundColor(TonicColors.accent)

            Text("Disk Analysis")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Analyze disk usage and find large files")
                .foregroundColor(.secondary)

            if !overviewEntries.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Quick Scan")
                        .font(.headline)
                        .padding(.horizontal)
                        .padding(.top, 12)

                    ForEach(overviewEntries) { entry in
                        OverviewEntryRow(entry: entry) {
                            navigateTo(entry.path)
                        }
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(12)
            }

            Button("Scan Current Folder") {
                Task { await scanCurrentPath() }
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
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

    private func navigateUp() {
        let parent = (currentPath as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != currentPath else { return }
        navigateTo(parent)
    }

    private func navigateTo(_ path: String) {
        navigationPath.append(currentPath)
        currentPath = path
        Task { await scanCurrentPath() }
    }

    // MARK: - Permissions

    private func checkPermissions() async {
        isCheckingPermissions = true
        let status = await permissionManager.checkPermission(.fullDiskAccess)
        hasFullDiskAccess = (status == .authorized)
        // checkPermission already updates the internal permissionStatuses
        isCheckingPermissions = false
    }

    private func grantFullDiskAccess() {
        _ = permissionManager.requestFullDiskAccess()
    }

    // MARK: - Scanning

    private func loadOverview() async {
        guard hasFullDiskAccess else { return }

        let paths = [
            homePath,
            "/Applications",
            "/Library",
            FileManager.default.homeDirectoryForCurrentUser.path + "/Library"
        ]

        do {
            overviewEntries = try await scanner.getOverviewSizes(for: paths) { path, size in
                // Update entry size
                if let index = overviewEntries.firstIndex(where: { $0.path == path }) {
                    overviewEntries[index].size = size
                }
            }
        } catch {
            // If overview scan fails, just continue without it
            overviewEntries = []
        }
    }

    private func scanCurrentPath() async {
        guard hasFullDiskAccess else {
            errorMessage = "Full Disk Access is required for disk scanning"
            return
        }

        isScanning = true
        errorMessage = nil
        scanResult = nil
        selectedPath = nil

        do {
            let result = try await scanner.scanPath(currentPath) { progress in
                scanProgress = progress
            }
            scanResult = result
        } catch {
            errorMessage = error.localizedDescription
        }

        isScanning = false
    }

    private func refreshScan() async {
        // Re-check permissions before scanning
        await checkPermissions()

        if hasFullDiskAccess {
            await scanCurrentPath()
        }
    }
}

// MARK: - Entry Row

struct EntryRow: View {
    let entry: DirEntry
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: entry.isDir ? "folder.fill" : "doc.fill")
                    .foregroundColor(iconColor)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.body)
                        .foregroundColor(.primary)

                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Size bar
                sizeBar
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
    }

    private var iconColor: Color {
        if entry.isDir {
            return .blue
        }
        return .secondary
    }

    private var sizeBar: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(0..<10) { i in
                    Rectangle()
                        .fill(barColor(for: i))
                        .frame(width: geometry.size.width / 12)
                }
            }
            .frame(height: 4)
        }
        .frame(width: 60)
    }

    private func barColor(for index: Int) -> Color {
        let threshold = Double(index) / 10.0
        let relativeSize = min(1.0, log2(Double(entry.size) + 1) / 50)

        if relativeSize > threshold {
            return TonicColors.accent
        }
        return Color.gray.opacity(0.2)
    }
}

// MARK: - Large File Row

struct LargeFileRow: View {
    let file: LargeFile
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "doc.fill")
                    .foregroundColor(.orange)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.body)
                        .foregroundColor(.primary)

                    Text((file.path as NSString).deletingLastPathComponent)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
    }
}

// MARK: - Overview Entry Row

struct OverviewEntryRow: View {
    let entry: DirectoryOverviewEntry
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .foregroundColor(.blue)
                    .frame(width: 20)

                Text(entry.name)
                    .font(.body)
                    .foregroundColor(.primary)

                Spacer()

                Text(entry.displaySize)
                    .font(.caption)
                    .foregroundColor(entry.isScanned ? .secondary : .orange)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    DiskAnalysisView()
}
