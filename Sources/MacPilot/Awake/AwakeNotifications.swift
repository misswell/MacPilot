import Foundation
import OSLog
import UserNotifications

//
//  AwakeNotifications.swift
//  MacPilot
//
//  Awake battery warnings delivered through UNUserNotificationCenter.
//

enum AwakeNotifications {
    private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "AwakeNotifications")

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                logger.error("Notification authorization denied: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func showBatteryWarning(threshold: Int) {
        let content = UNMutableNotificationContent()
        content.title = AppText.value("awakeNotifyBatteryTitle", language: .english)
        content.body = String(
            format: AppText.value("awakeNotifyBatteryBody", language: .english),
            threshold
        )
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "com.misswell.macpilot.awake.battery.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
