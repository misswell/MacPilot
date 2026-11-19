import SwiftUI

struct ImageViewerAssociationCard: View {
    let language: AppLanguage
    @StateObject private var model = ImageViewerAssociations()
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        SettingsCard {
            HStack {
                Text(t("viewerAssociations")).font(.headline)
                Spacer()
                Button(t("viewerAssociationRefresh")) { model.refresh() }
                    .disabled(model.isApplying)
            }
            Text(t("viewerAssociationHint")).font(.subheadline).foregroundStyle(.secondary)
            if model.rows.isEmpty {
                Text(t("viewerAssociationEmpty")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.rows) { row in
                if row.id != model.rows.first?.id { Divider() }
                HStack {
                    Text(row.format.title).font(.subheadline.weight(.medium))
                    Spacer()
                    Menu {
                        ForEach(row.choices, id: \.self) { app in
                            Button {
                                Task { await model.change(row.id, to: app) }
                            } label: {
                                if app == row.current {
                                    Label(appName(app, in: row), systemImage: "checkmark")
                                } else {
                                    Text(appName(app, in: row))
                                }
                            }
                            .disabled(app == row.current)
                            .help(app.path)
                        }
                    } label: {
                        Text(row.current.map { appName($0, in: row) } ?? t("viewerAssociationNoDefault"))
                    }
                    .fixedSize()
                    .disabled(model.isApplying || row.choices.isEmpty)
                    .accessibilityLabel(t("viewerAssociationForFormat", row.format.title))
                    .accessibilityValue(row.current.map { appName($0, in: row) } ?? t("viewerAssociationNoDefault"))
                }
                if let notice = model.notices[row.id] {
                    Text(message(for: notice)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { model.refresh() }
        .onChange(of: controlActiveState) { _, state in
            if state == .key { model.refresh() }
        }
    }

    private func appName(_ url: URL, in row: ImageViewerAssociations.Row) -> String {
        if url == row.macPilot { return "MacPilot" }
        let raw = FileManager.default.displayName(atPath: url.path)
        return raw.hasSuffix(".app") ? String(raw.dropLast(4)) : raw
    }

    private func message(for notice: ImageViewerAssociations.Notice) -> String {
        switch notice {
        case .changed: t("viewerAssociationChanged")
        case .unchanged: t("viewerAssociationUnchanged")
        case .cancelled: t("viewerAssociationCancelled")
        case .failed(let reason): t("viewerAssociationFailed", reason)
        }
    }

    private func t(_ key: String, _ arguments: CVarArg...) -> String {
        AppText.value(key, language: language, arguments: arguments)
    }
}
