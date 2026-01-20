//
//  DeepCleanView.swift
//  Tonic
//
//  Deep clean view for comprehensive system cleanup
//  Task ID: fn-1.7
//

import SwiftUI

struct DeepCleanView: View {
    @State private var engine = DeepCleanEngine.shared
    @State private var scanResults: [DeepCleanResult] = []
    @State private var selectedCategories: Set<DeepCleanCategory> = []
    @State private var isScanning = false
    @State private var isCleaning = false
    @State private var cleanProgress: Double = 0
    @State private var bytesFreed: Int64 = 0

    private let totalSizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            if isScanning {
                scanningProgress
            } else if isCleaning {
                cleaningProgress
            } else if scanResults.isEmpty {
                initialView
            } else {
                resultsView
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Deep Clean")
                .font(.headline)

            Spacer()

            if !scanResults.isEmpty {
                Button("Rescan") {
                    Task { await performScan() }
                }
                .disabled(isScanning || isCleaning)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Progress Views

    private var scanningProgress: some View {
        VStack(spacing: 16) {
            Spacer()

            ProgressView()
                .scaleEffect(1.5)

            if let currentCategory = engine.currentScanningCategory {
                Text("Scanning \(currentCategory)...")
                    .foregroundColor(.secondary)
            }

            Text("This may take a moment")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()
        }
    }

    private var cleaningProgress: some View {
        VStack(spacing: 16) {
            Spacer()

            ProgressView(value: cleanProgress)
                .progressViewStyle(.linear)

            Text("Cleaning: \(Int(cleanProgress * 100))%")
                .font(.headline)

            Text("Freed so far: \(totalSizeFormatter.string(fromByteCount: bytesFreed))")
                .foregroundColor(.secondary)

            Spacer()
        }
    }

    // MARK: - Initial View

    private var initialView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundColor(TonicColors.accent)

            Text("Deep Clean")
                .font(.title)
                .fontWeight(.semibold)

            Text("Scan and clean unnecessary files from all areas of your Mac")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding()

            VStack(alignment: .leading, spacing: 12) {
                categoryRow(.systemCache)
                categoryRow(.userCache)
                categoryRow(.logFiles)
                categoryRow(.tempFiles)
                categoryRow(.development)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(12)

            Button("Start Scan") {
                Task { await performScan() }
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
    }

    // MARK: - Results View

    private var resultsView: some View {
        VStack(spacing: 0) {
            // Summary
            summaryBar

            Divider()

            // Category list
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(scanResults) { result in
                        CategoryResultRow(
                            result: result,
                            isSelected: selectedCategories.contains(result.category)
                        ) {
                            toggleCategory(result.category)
                        }
                    }
                }
            }

            // Clean button
            cleanButton
        }
    }

    private var summaryBar: some View {
        HStack {
            let totalSize = scanResults.reduce(0) { $0 + $1.totalSize }
            Text(totalSizeFormatter.string(fromByteCount: totalSize))
                .font(.headline)

            Spacer()

            Text("\(selectedCategories.count) categories selected")
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var cleanButton: some View {
        VStack(spacing: 8) {
            if selectedCategories.isEmpty {
                Text("Select categories to clean")
                    .foregroundColor(.secondary)
            } else {
                let selectedSize = scanResults
                    .filter { selectedCategories.contains($0.category) }
                    .reduce(0) { $0 + $1.totalSize }

                Button {
                    Task { await performClean() }
                } label: {
                    Text("Clean \(totalSizeFormatter.string(fromByteCount: selectedSize))")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(selectedCategories.isEmpty ? Color.gray : TonicColors.accent)
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(selectedCategories.isEmpty || isCleaning)
            }
        }
        .padding()
    }

    // MARK: - Helper Views

    private func categoryRow(_ category: DeepCleanCategory) -> some View {
        HStack {
            Image(systemName: category.icon)
                .foregroundColor(.blue)
                .frame(width: 24)

            Text(category.rawValue)
                .font(.body)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func performScan() async {
        isScanning = true
        selectedCategories.removeAll()
        bytesFreed = 0

        let results = await engine.scanAllCategories()
        scanResults = results.filter { $0.totalSize > 0 }

        isScanning = false
    }

    private func performClean() async {
        isCleaning = true

        let categories = Array(selectedCategories)
        let freed = await engine.cleanCategories(categories)

        bytesFreed += freed

        // Refresh scan results
        let results = await engine.scanAllCategories()
        scanResults = results.filter { $0.totalSize > 0 }

        selectedCategories.removeAll()

        isCleaning = false
        cleanProgress = 0
    }

    private func toggleCategory(_ category: DeepCleanCategory) {
        if selectedCategories.contains(category) {
            selectedCategories.remove(category)
        } else {
            selectedCategories.insert(category)
        }
    }
}

// MARK: - Category Result Row

struct CategoryResultRow: View {
    let result: DeepCleanResult
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? TonicColors.accent : .gray)
                    .font(.title3)

                Image(systemName: result.category.icon)
                    .foregroundColor(.blue)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(result.category.rawValue)
                        .font(.body)
                    Text("\(result.itemCount) items • \(result.formattedSize)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(result.category.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 150, alignment: .trailing)
            }
            .padding()
            .background(isSelected ? TonicColors.accent.opacity(0.1) : Color.clear)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    DeepCleanView()
}
