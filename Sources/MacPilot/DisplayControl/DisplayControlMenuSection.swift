import MacPilotDisplayControlCore
import SwiftUI

enum DisplayControlMenuPolicy {
    static func target(uuid: String?, displays: [DisplayControlDisplay]) -> DisplayControlDisplay? {
        guard let uuid else { return nil }
        return displays.first { $0.uuid == uuid && $0.isUsable }
    }

    static func canDisable(_ target: DisplayControlDisplay?, displays: [DisplayControlDisplay]) -> Bool {
        guard let target else { return false }
        return DisplayControlSafety.canDisable(
            targetUUID: target.uuid, displays: displays, policy: .localPhysical,
            remoteSessionIsFresh: false, virtualSelectionConfirmed: false,
            confirmedVirtualUUID: nil
        )
    }

    static func canKeepOnly(_ target: DisplayControlDisplay?, displays: [DisplayControlDisplay]) -> Bool {
        guard let uuid = target?.uuid,
              let current = Self.target(uuid: uuid, displays: displays), !current.isVirtual else { return false }
        return true
    }
}

struct DisplayControlMenuSection: View {
    @ObservedObject var control: DisplayControlModel
    @ObservedObject var context: MenuBarDisplayController

    var body: some View {
        let uuid = context.targetUUID
        let target = DisplayControlMenuPolicy.target(uuid: uuid, displays: control.displays)
        Menu(control.t("displayMenuCurrentScreen")) {
            if let target {
                Text(target.isBuiltIn ? control.t("displayKindBuiltIn") : target.name)
            } else {
                Text(control.t("displayMenuUnknownScreen"))
            }
            Button(control.t("displayMenuDisableCurrent")) {
                // Defer until NSMenu has finished tracking. Revalidate the
                // frozen UUID against fresh model state, never the cursor.
                DispatchQueue.main.async {
                    guard let target = DisplayControlMenuPolicy.target(uuid: uuid, displays: control.displays),
                          DisplayControlMenuPolicy.canDisable(target, displays: control.displays) else { return }
                    control.disable(target)
                }
            }
            .disabled(!control.canChange || !DisplayControlMenuPolicy.canDisable(target, displays: control.displays))
            Button(control.t("displayMenuKeepCurrent")) {
                DispatchQueue.main.async {
                    guard let target = DisplayControlMenuPolicy.target(uuid: uuid, displays: control.displays),
                          DisplayControlMenuPolicy.canKeepOnly(target, displays: control.displays) else { return }
                    control.keepOnly(target)
                }
            }
            .disabled(!control.canChange || !DisplayControlMenuPolicy.canKeepOnly(target, displays: control.displays))
        }
    }
}
