import SwiftUI

struct ImageViewerHomeView: View {
    @ObservedObject var runtime: ImageViewerRuntime
    let language: AppLanguage

    private func t(_ key: String) -> String { AppText.value(key, language: language) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(t("imageViewer")).font(.system(size: 30, weight: .bold))
                    Text(t("imageViewerSubtitle")).foregroundStyle(.secondary)
                }
                SettingsCard {
                    HStack {
                        Button(t("viewerOpenImage")) { runtime.chooseFiles() }
                            .macPilotProminentButtonStyle()
                        Button(t("viewerOpenFolder")) { runtime.chooseFolder() }
                        Button(t("viewerOpenBatch")) { runtime.chooseFiles(multiple: true) }
                    }
                    Text(t("viewerDropHint")).font(.caption).foregroundStyle(.secondary)
                    Text(t("viewerFinderHint")).font(.caption).foregroundStyle(.secondary)
                }
                SettingsCard {
                    Text(t("viewerRecents")).font(.headline)
                    if runtime.recents.isEmpty {
                        Text(t("viewerNoRecents")).font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(runtime.recents, id: \.self) { url in
                        Button { runtime.open([url]) } label: {
                            Label(url.lastPathComponent, systemImage: "photo")
                                .lineLimit(1)
                        }
                        .help(url.path)
                    }
                }
            }
            .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 30)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let documents = ImageViewerFileRouter.documents(in: urls)
            guard !documents.isEmpty else { return false }
            runtime.open(documents)
            return true
        }
    }
}

struct ImageViewerWindowContent: View {
    @ObservedObject var controller: ImageViewerWindowController
    @State private var pageEntry = ""

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ImageViewerCanvasView(controller: controller)
                if controller.loading {
                    ProgressView(controller.t("viewerLoading")).controlSize(.small)
                        .allowsHitTesting(false)
                } else if let error = controller.errorKey {
                    Text(controller.t(error)).padding().allowsHitTesting(false)
                }
            }
            Divider()
            statusBar
        }
        .popover(isPresented: $controller.showsInformation, arrowEdge: .top) {
            information
        }
        .onChange(of: controller.browser.page, initial: true) { _, current in pageEntry = String(current) }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text(controller.browser.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            if let index = controller.browser.index {
                let selection = controller.browser.selection.map { String($0 + 1) } ?? "–"
                Text("\(selection) / \(index.files.count)")
                if index.truncated { Text(controller.t("viewerIndexLimit")) }
            }
            if controller.indexError { Text(controller.t("viewerIndexError")) }
            Spacer(minLength: 0)
            if let percent = controller.zoomPercent { Text("\(percent)%") }
            if controller.browser.url.pathExtension.lowercased() == "pdf", controller.frame != nil {
                Button { controller.go(to: controller.browser.page - 1) } label: { Image(systemName: "chevron.up") }
                    .disabled(controller.browser.page <= 1)
                    .accessibilityLabel(controller.t("viewerPreviousPage"))
                TextField(controller.t("viewerPage"), text: $pageEntry)
                    .labelsHidden()
                    .frame(width: 46)
                    .onSubmit {
                        if let page = Int(pageEntry) { controller.go(to: page) }
                        pageEntry = String(controller.browser.page)
                    }
                Text("/ \(controller.browser.pageCount)")
                Button { controller.go(to: controller.browser.page + 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(controller.browser.page >= controller.browser.pageCount)
                    .accessibilityLabel(controller.t("viewerNextPage"))
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(controller.t("viewerCommand_info")).font(.headline)
            if let information = controller.information {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                    ForEach(information.rows, id: \.key) { row in
                        GridRow {
                            Text(controller.t(row.key)).foregroundStyle(.secondary)
                            Text(row.value).textSelection(.enabled)
                        }
                    }
                }
                .font(.callout)
            } else if let error = controller.informationError {
                Text(controller.t(error))
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(16)
        .frame(minWidth: 240, maxWidth: 440, alignment: .leading)
    }
}
