import SwiftUI

/// Trackpad preferences as a sheet: tracking speed, scroll direction, tap to
/// click, inertia — plus the gesture legend, because nobody guesses
/// "two-finger tap = right click" on their own.
struct TrackpadSettingsView: View {
    @ObservedObject var model: RemoteTrackpadModel
    @EnvironmentObject private var appModel: RemoteAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(appModel.text("trackpadTrackingSpeed"))
                        Slider(
                            value: Binding(
                                get: { model.settings.trackingSpeed },
                                set: { model.settings.trackingSpeed = $0 }
                            ),
                            in: 0.5...2
                        )
                    }
                    Toggle(
                        appModel.text("trackpadNaturalScrolling"),
                        isOn: Binding(
                            get: { model.settings.naturalScrolling },
                            set: { model.settings.naturalScrolling = $0 }
                        )
                    )
                    Toggle(
                        appModel.text("trackpadTapToClick"),
                        isOn: Binding(
                            get: { model.settings.tapToClick },
                            set: { model.settings.tapToClick = $0 }
                        )
                    )
                    Toggle(
                        appModel.text("trackpadScrollInertia"),
                        isOn: Binding(
                            get: { model.settings.scrollInertia },
                            set: { model.settings.scrollInertia = $0 }
                        )
                    )
                } header: {
                    Text(appModel.text("trackpadSettings"))
                } footer: {
                    Text(appModel.text("trackpadGesturesHint"))
                }
            }
            .navigationTitle(appModel.text("trackpadTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(appModel.text("trackpadDone")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
