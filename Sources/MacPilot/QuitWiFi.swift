import AppKit
import Combine
import CoreLocation
import CoreWLAN
import SwiftUI

/// SSIDs are case-sensitive. Only line endings delimit names, so commas remain valid.
enum QuitWiFiPolicy {
    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: .newlines).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func matches(names: [String]?, connectedNames: Set<String>) -> Bool {
        (names ?? []).contains { !$0.isEmpty && connectedNames.contains($0) }
    }
}

private func isAuthorizedForWiFiNameAccess(_ status: CLAuthorizationStatus) -> Bool {
    status == .authorizedAlways
}

/// Reads only associated networks; never scans or collects geographic coordinates.
@MainActor
final class QuitWiFiMonitor: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var connectedNames = Set<String>()
    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        return manager
    }()
    private var task: Task<Void, Never>?
    private var generation = 0
    private var onChange: (() -> Void)?
    private let authorizationStatusProvider: (@MainActor () -> CLAuthorizationStatus)?
    private let connectedNamesReader: @MainActor () async -> Set<String>

    init(
        authorizationStatusProvider: (@MainActor () -> CLAuthorizationStatus)? = nil,
        connectedNamesReader: (@MainActor () async -> Set<String>)? = nil
    ) {
        self.authorizationStatusProvider = authorizationStatusProvider
        self.connectedNamesReader = connectedNamesReader ?? {
            await Task.detached(priority: .utility) {
                Set((CWWiFiClient.shared().interfaces() ?? []).compactMap { interface in
                    guard interface.powerOn(), let name = interface.ssid(), !name.isEmpty else { return nil }
                    return name
                })
            }.value
        }
        super.init()
    }

    private func currentAuthorizationStatus() -> CLAuthorizationStatus {
        authorizationStatusProvider?() ?? locationManager.authorizationStatus
    }

    func prepareAccess() {
        authorization = currentAuthorizationStatus()
    }

    func requestAccess() {
        prepareAccess()
        locationManager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if !isAuthorizedForWiFiNameAccess(authorization) {
            connectedNames = []
            onChange?()
        }
    }

    func configure(enabled: Bool, onChange: @escaping () -> Void) {
        guard enabled else { stop(); return }
        self.onChange = onChange
        guard task == nil else { return }
        generation += 1
        let currentGeneration = generation
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let status = self.currentAuthorizationStatus()
                self.authorization = status
                let allowed = isAuthorizedForWiFiNameAccess(status)
                let names: Set<String>
                if allowed {
                    names = await self.connectedNamesReader()
                } else {
                    names = []
                }
                guard !Task.isCancelled, self.generation == currentGeneration else { return }
                let latestAuthorization = self.currentAuthorizationStatus()
                self.authorization = latestAuthorization
                let acceptedNames = isAuthorizedForWiFiNameAccess(latestAuthorization) ? names : []
                if self.connectedNames != acceptedNames {
                    self.connectedNames = acceptedNames
                    self.onChange?()
                }
                do { try await Task.sleep(for: .seconds(10)) }
                catch { return }
            }
        }
    }

    func stop() {
        generation += 1
        task?.cancel()
        task = nil
        connectedNames = []
        onChange = nil
    }
}

struct QuitWiFiEditor: View {
    @EnvironmentObject private var model: MacPilotModel
    @StateObject private var access = QuitWiFiMonitor()
    @Binding var enabled: Bool
    @Binding var names: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(model.t("quitWiFi"), isOn: $enabled).toggleStyle(.switch)
            if enabled {
                TextEditor(text: $names)
                    .font(.body)
                    .frame(height: 58)
                    .border(.quaternary)
                    .accessibilityLabel(model.t("quitWiFiPlaceholder"))
                Text(model.t("quitWiFiHint")).font(.caption).foregroundStyle(.secondary)
                Text(model.t("quitWiFiPermission")).font(.caption).foregroundStyle(.secondary)
                if access.authorization == .denied || access.authorization == .restricted {
                    Button(model.t("quitWiFiSettings")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } else if !isAuthorizedForWiFiNameAccess(access.authorization) {
                    Button(model.t("quitWiFiAuthorize")) { access.requestAccess() }
                }
            }
        }
        .onAppear { access.prepareAccess() }
        .onDisappear { access.stop() }
    }
}
