//
//  RecordingNotifications.swift
//  MacPilot
//
//  Completion/failure notifications for the recording feature, delivered
//  through UNUserNotificationCenter.
//

import Foundation
import OSLog
import UserNotifications

enum ScreenRecordingNotifications {
    private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "ScreenRecordingNotifications")

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error {
                logger.error("Notification authorization denied: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func show(titleKey: String, bodyKey: String, arguments: [CVarArg] = []) {
        let content = UNMutableNotificationContent()
        content.title = AppText.value(titleKey, language: .english)
        let bodyTemplate = AppText.value(bodyKey, language: .english)
        content.body = arguments.isEmpty ? bodyTemplate : String(format: bodyTemplate, arguments: arguments)
        content.sound = UNNotificationSound.default
        let request = UNNotificationRequest(
            identifier: "com.misswell.macpilot.recording.\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }
}
