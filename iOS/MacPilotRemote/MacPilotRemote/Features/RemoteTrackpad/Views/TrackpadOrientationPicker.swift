import SwiftUI

/// The portrait/landscape control. It changes the delta mapping only — the
/// system never rotates the page, because someone holding the phone flat must
/// not have the surface flip under their fingers.
struct TrackpadOrientationPicker: View {
    let model: RemoteTrackpadModel
    let text: (String) -> String

    var body: some View {
        Menu {
            ForEach(TrackpadOrientation.allCases, id: \.self) { orientation in
                Button {
                    model.setOrientation(orientation)
                } label: {
                    Label(
                        text(orientation == .portrait ? "trackpadPortrait" : "trackpadLandscape"),
                        systemImage: orientation == model.orientation ? "checkmark" : orientation.iconSystemName
                    )
                }
            }
        } label: {
            Image(systemName: model.orientation.iconSystemName)
                .font(.body.weight(.medium))
                .frame(width: 44, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                )
        }
        .accessibilityLabel(text("trackpadOrientation"))
    }
}
