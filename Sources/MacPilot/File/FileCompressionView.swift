import Foundation
import SwiftUI

struct FileCompressionView: View {
    @EnvironmentObject private var appModel: MacPilotModel
    @ObservedObject var compression: FolderCompressionModel
    @State private var extensionText = ""
    @State private var folderPendingRemoval: String?
    @State private var showsAutomaticCompressionInfo = false
    @State private var compressedFileInspection: CompressedFileInspection?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(t("fileCompression"))
                    .font(.system(size: 30, weight: .bold))
                Text(t("fileCompressionSubtitle"))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 36)
            .padding(.top, 34)
            .padding(.bottom, 22)

            ScrollView {
                VStack(spacing: 24) {
                    folderCard
                    rulesCard
                    resultsCard
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 30)
            }
        }
        .onAppear { extensionText = compression.settings.fileExtensions.joined(separator: ", ") }
        .onChange(of: compression.settings.fileExtensions) { _, newValue in
            extensionText = newValue.joined(separator: ", ")
        }
        .alert(
            t("compressionRemoveFolderTitle"),
            isPresented: Binding(
                get: { folderPendingRemoval != nil },
                set: { if !$0 { folderPendingRemoval = nil } }
            ),
            presenting: folderPendingRemoval
        ) { path in
            Button(t("compressionRemoveFolder"), role: .destructive) {
                compression.removeFolder(path: path)
                folderPendingRemoval = nil
            }
            Button(t("cancel"), role: .cancel) {
                folderPendingRemoval = nil
            }
        } message: { path in
            Text(t("compressionRemoveFolderMessage", path))
        }
        .sheet(item: $compressedFileInspection) { inspection in
            CompressedFileListSheet(
                settings: inspection.settings,
                language: appModel.language
            )
        }
    }

    private var folderCard: some View {
        SettingsCard {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13)
                        .fill(Color.cyan.opacity(0.13))
                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.cyan)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 4) {
                    Text(t("compressionFolder"))
                        .font(.headline)
                    Text(compression.settings.folderPaths.isEmpty
                         ? t("compressionNoFolder")
                         : t("compressionFolderCount", compression.settings.folderPaths.count))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(t("compressionAddFolders"), action: chooseFolders)
                    .buttonStyle(.bordered)
                    .disabled(compression.isScanning || compression.isProcessing)
            }

            Divider()

            if !compression.settings.folderPaths.isEmpty {
                VStack(spacing: 0) {
                    ForEach(compression.settings.folderPaths, id: \.self) { path in
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.cyan)
                                .frame(width: 18)
                            Text(path)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                folderPendingRemoval = path
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help(t("compressionRemoveFolder"))
                            .disabled(compression.isScanning || compression.isProcessing)
                        }
                        .padding(.vertical, 7)
                    }
                }
                Divider()
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(t("compressionAutomatic"))
                    Button {
                        showsAutomaticCompressionInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.cyan)
                    }
                    .buttonStyle(.plain)
                    .help(t("compressionAutomaticInfoHelp"))
                    .popover(isPresented: $showsAutomaticCompressionInfo, arrowEdge: .trailing) {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(t("compressionAutomaticInfo"), systemImage: "wave.3.right.circle.fill")
                                .font(.headline)
                                .foregroundStyle(.cyan)
                            Text(t("compressionAutomaticInfoBody"))
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(18)
                        .frame(width: 390, alignment: .leading)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { compression.settings.automaticallyCompress },
                        set: { compression.setAutomaticallyCompress($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(t("compressionAutomatic"))
                }
                Text(t("compressionAutomaticHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(compression.settings.folderPaths.isEmpty)
        }
    }

    private var rulesCard: some View {
        SettingsCard {
            Label(t("compressionRules"), systemImage: "slider.horizontal.3")
                .font(.headline)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(t("compressionExtensions"))
                    Spacer()
                    Button(t("compressionRecommended")) {
                        compression.useRecommendedExtensions()
                    }
                    .buttonStyle(.link)
                }
                HStack {
                    TextField("txt, log, json", text: $extensionText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { applyExtensions() }
                    Button(t("compressionApply"), action: applyExtensions)
                }
                Text(t("compressionExtensionsHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 22) {
                rulePicker(
                    title: t("compressionMinimumSize"),
                    selection: Binding(
                        get: { compression.settings.minimumFileSize },
                        set: { compression.setMinimumFileSize($0) }
                    ),
                    values: [1_048_576, 5_242_880, 10_485_760, 52_428_800],
                    label: { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                )
                rulePicker(
                    title: t("compressionStableFor"),
                    selection: Binding(
                        get: { Int64(compression.settings.stableSeconds) },
                        set: { compression.setStableSeconds(TimeInterval($0)) }
                    ),
                    values: [600, 1_800, 3_600],
                    label: { t("compressionMinutesValue", Int($0 / 60)) }
                )
                rulePicker(
                    title: t("compressionMinimumSavings"),
                    selection: Binding(
                        get: { Int64(compression.settings.minimumSavingsPercent) },
                        set: { compression.setMinimumSavingsPercent(Int($0)) }
                    ),
                    values: [10, 20, 30],
                    label: { "\($0)%" }
                )
            }

            Label(t("compressionSafetyHint"), systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var resultsCard: some View {
        SettingsCard {
            HStack {
                Label(t("compressionAnalysis"), systemImage: "chart.bar.doc.horizontal")
                    .font(.headline)
                Spacer()
                if compression.isScanning || compression.isProcessing {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(t("compressionScanNow")) {
                    Task { await compression.scanNow() }
                }
                .disabled(compression.settings.folderPaths.isEmpty || compression.isScanning || compression.isProcessing)
            }

            if let error = compression.error {
                Label(errorText(error), systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            } else if let scan = compression.scan {
                scanSummary(scan)
                folderIssuePreview(scan)
                filePreview(scan)
                operationButtons(scan)
            } else {
                VStack(spacing: 9) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(t("compressionScanPrompt"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }

            if compression.isProcessing {
                Divider()
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(t(compression.lastActionWasRestore ? "compressionRestoring" : "compressionCompressing"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            } else if let result = compression.lastResult {
                Divider()
                Label(resultText(result), systemImage: result.failedCount == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(result.failedCount == 0 ? .green : .orange)
                if let failure = result.failedFiles.first {
                    Text(t("compressionFailedFile", failure))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let failure = result.failures.first {
                    Text(errorText(failure))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let recovery = result.recoveryFiles.first {
                    Text(t("compressionRecoveryPreserved", recovery))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func folderIssuePreview(_ scan: FileCompressionScan) -> some View {
        if !scan.folderIssues.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(scan.folderIssues, id: \.folderURL) { issue in
                    Label(
                        t("compressionFolderIssue", issue.folderURL.path, errorText(issue.error)),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                }
            }
        }
    }

    private func scanSummary(_ scan: FileCompressionScan) -> some View {
        HStack(spacing: 0) {
            summaryMetric(
                value: "\(scan.candidateCount)",
                label: t("compressionCandidates"),
                detail: t(
                    "compressionSizeDetail",
                    byteString(scan.candidateBytes),
                    byteString(scan.candidateAllocatedBytes)
                ),
                color: .cyan
            )
            Divider().frame(height: 54).padding(.horizontal, 22)
            summaryMetric(
                value: "\(scan.compressedCount)",
                label: t("compressionAlreadyCompressed"),
                detail: t("compressionUses", byteString(scan.compressedAllocatedBytes)),
                color: .indigo
            )
            Divider().frame(height: 54).padding(.horizontal, 22)
            summaryMetric(
                value: byteString(max(0, scan.compressedLogicalBytes - scan.compressedAllocatedBytes)),
                label: t("compressionSpaceSaved"),
                detail: t("compressionLogical", byteString(scan.compressedLogicalBytes)),
                color: .green
            )
            Spacer(minLength: 0)
        }
        .padding(15)
        .background(Color.cyan.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func filePreview(_ scan: FileCompressionScan) -> some View {
        let items = Array((scan.candidates.map { ($0, false) } + scan.compressedFiles.map { ($0, true) }).prefix(8))
        if !items.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.0.id) { index, item in
                    HStack(spacing: 10) {
                        Image(systemName: item.1 ? "archivebox.fill" : "doc.text")
                            .foregroundStyle(item.1 ? .indigo : .secondary)
                            .frame(width: 18)
                        Text(item.0.displayPath)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(t(
                            "compressionSizeDetail",
                            byteString(item.0.logicalSize),
                            byteString(item.0.allocatedSize)
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 7)
                    if index < items.count - 1 { Divider() }
                }
                if scan.compressedCount > 0 {
                    Divider()
                    Button {
                        compressedFileInspection = CompressedFileInspection(settings: compression.settings)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "list.bullet.rectangle.portrait.fill")
                            Text(t("compressionViewAllCompressed", scan.compressedCount))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.indigo)
                    .padding(.vertical, 9)
                }
            }
        }
    }

    private func operationButtons(_ scan: FileCompressionScan) -> some View {
        HStack {
            Button {
                Task { await compression.compressCandidates() }
            } label: {
                Label(t("compressionCompressFiles", scan.candidateCount), systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(.borderedProminent)
            .disabled(scan.candidateCount == 0 || compression.isProcessing || compression.isScanning)

            Button {
                Task { await compression.restoreCompressedFiles() }
            } label: {
                Label(t("compressionRestoreFiles", scan.compressedCount), systemImage: "arrow.uturn.backward")
            }
            .disabled(scan.compressedCount == 0 || compression.isProcessing || compression.isScanning)
            Spacer()
        }
    }

    private func summaryMetric(value: String, label: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(label).font(.caption.weight(.medium))
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func rulePicker(
        title: String,
        selection: Binding<Int64>,
        values: [Int64],
        label: @escaping (Int64) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(values, id: \.self) { value in Text(label(value)).tag(value) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = t("compressionChoose")
        guard panel.runModal() == .OK else { return }
        compression.addFolders(panel.urls)
        Task { await compression.scanNow() }
    }

    private func applyExtensions() {
        compression.updateExtensions(extensionText)
        extensionText = compression.settings.fileExtensions.joined(separator: ", ")
    }

    private func resultText(_ result: FileCompressionOperationResult) -> String {
        if compression.lastActionWasRestore {
            return t("compressionRestoreResult", result.restoredCount, result.failedCount)
        }
        return t(
            "compressionCompressResult",
            result.compressedCount,
            byteString(result.bytesSaved),
            result.skippedCount,
            result.failedCount
        )
    }

    private func errorText(_ error: AppleFileCompressionError) -> String {
        switch error {
        case .folderNotSelected:
            t("compressionErrorNoFolder")
        case .folderUnavailable:
            t("compressionErrorFolderUnavailable")
        case .unsupportedFileSystem(let name):
            t("compressionErrorFileSystem", name)
        case .scanFailed(let message):
            t("compressionErrorScan", message)
        case .fileChanged:
            t("compressionErrorFileChanged")
        case .compressionUnavailable:
            t("compressionErrorUnavailable")
        case .verificationFailed:
            t("compressionErrorVerification")
        case .commandFailed(let message):
            t("compressionErrorCommand", message)
        case .coordinationFailed(let message):
            t("compressionErrorCoordination", message)
        case .fileInUse:
            t("compressionErrorFileInUse")
        case .monitoringUnavailable:
            t("compressionErrorMonitoringUnavailable")
        case .recoveryCopyPreserved(let path):
            t("compressionRecoveryPreserved", path)
        case .replacementFailed:
            t("compressionErrorReplacement")
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func t(_ key: String, _ arguments: CVarArg...) -> String {
        AppText.value(key, language: appModel.language, arguments: arguments)
    }
}

private struct CompressedFileInspection: Identifiable {
    let id = UUID()
    let settings: FolderCompressionSettings
}

private struct CompressedFileListSheet: View {
    let settings: FolderCompressionSettings
    let language: AppLanguage

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var sortOrder = FileCompressionSortOrder.logicalSize
    @State private var pageCursors: [FileCompressionCandidate?] = [nil]
    @State private var pageIndex = 0
    @State private var page = FileCompressionPage(files: [], matchingCount: 0, hasMore: false)
    @State private var isLoading = false

    private var pageKey: String { "\(searchText)|\(sortOrder.rawValue)|\(pageIndex)" }

    var body: some View {
        let displayedFiles = page.files
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.indigo.opacity(0.13))
                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.indigo)
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("compressionCompressedListTitle"))
                        .font(.title3.weight(.semibold))
                    Text("\(page.matchingCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(t("compressionClose")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)

            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(t("compressionSearchFiles"), text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))

                Picker(t("compressionSortBy"), selection: $sortOrder) {
                    Text(t("compressionSortLogicalSize")).tag(FileCompressionSortOrder.logicalSize)
                    Text(t("compressionSortActualSize")).tag(FileCompressionSortOrder.allocatedSize)
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)

            Divider()
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if displayedFiles.isEmpty {
                ContentUnavailableView(
                    t("compressionNoMatchingFiles"),
                    systemImage: "doc.text.magnifyingglass"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(displayedFiles.enumerated()), id: \.element.id) { index, file in
                            HStack(spacing: 11) {
                                Image(systemName: "archivebox.fill")
                                    .foregroundStyle(.indigo)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(file.url.lastPathComponent)
                                        .lineLimit(1)
                                    Text(file.displayPath)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 12)
                                Text(sizeDetail(file))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                                } label: {
                                    Image(systemName: "folder")
                                }
                                .buttonStyle(.borderless)
                                .help(t("revealInFinder"))
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            if index < displayedFiles.count - 1 {
                                Divider().padding(.leading, 47)
                            }
                        }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Button(t("compressionPreviousPage")) { pageIndex -= 1 }
                    .disabled(pageIndex == 0 || isLoading)
                Spacer()
                Text("\(pageIndex + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(t("compressionNextPage")) {
                    guard let last = page.files.last else { return }
                    if pageCursors.count <= pageIndex + 1 { pageCursors.append(last) }
                    pageIndex += 1
                }
                .disabled(!page.hasMore || isLoading)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .frame(width: 760, height: 520)
        .onChange(of: searchText) { _, _ in resetPages() }
        .onChange(of: sortOrder) { _, _ in resetPages() }
        .task(id: pageKey) {
            isLoading = true
            let search = searchText
            let sort = sortOrder
            let cursor = pageCursors[pageIndex]
            let task = Task.detached(priority: .userInitiated) { [settings] in
                try AppleFileCompressionEngine().compressedPage(
                    settings: settings, search: search, sort: sort, after: cursor
                )
            }
            do {
                let loaded = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
                guard !Task.isCancelled else { return }
                page = loaded
            } catch {
                page = FileCompressionPage(files: [], matchingCount: 0, hasMore: false)
            }
            isLoading = false
        }
    }

    private func resetPages() {
        pageCursors = [nil]
        pageIndex = 0
    }

    private func sizeDetail(_ file: FileCompressionCandidate) -> String {
        t(
            "compressionSizeDetail",
            ByteCountFormatter.string(fromByteCount: file.logicalSize, countStyle: .file),
            ByteCountFormatter.string(fromByteCount: file.allocatedSize, countStyle: .file)
        )
    }

    private func t(_ key: String, _ arguments: CVarArg...) -> String {
        AppText.value(key, language: language, arguments: arguments)
    }
}
