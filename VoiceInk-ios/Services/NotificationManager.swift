//
//  NotificationManager.swift
//  VoiceInk-ios
//
//  Manages persistent notifications to keep app active in background
//

import Foundation
import UserNotifications
import UIKit

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()
    
    private let notificationIdentifier = "com.asterayx.VoiceInk.activeSession"
    
    private init() {
        requestNotificationPermission()
    }
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                Logger.warning("Permission request failed: \(error.localizedDescription)", category: "NotificationManager")
            } else {
                Logger.info("Notification permission granted: \(granted)", category: "NotificationManager")
            }
        }
    }
    
    /// Show persistent notification when session is active in keyboard mode
    func showActiveSessionNotification() {
        let content = UNMutableNotificationContent()
        content.title = "VoiceInk Active"
        content.body = "Recording session active - tap to return to app"
        content.sound = .default
        content.categoryIdentifier = "ACTIVE_SESSION"
        
        // Make it a persistent notification that doesn't auto-dismiss
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false) // 1 hour, but we'll update it
        
        let request = UNNotificationRequest(
            identifier: notificationIdentifier,
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Logger.error("Failed to show notification: \(error.localizedDescription)", category: "NotificationManager")
            } else {
                Logger.info("Active session notification shown", category: "NotificationManager")
            }
        }
    }
    
    /// Update notification with remaining time
    func updateNotification(timeRemaining: TimeInterval) {
        let minutes = Int(timeRemaining) / 60
        let seconds = Int(timeRemaining) % 60
        
        let content = UNMutableNotificationContent()
        content.title = "VoiceInk Active"
        content.body = "Recording session active (\(minutes):\(String(format: "%02d", seconds)) remaining)"
        content.sound = .default
        content.categoryIdentifier = "ACTIVE_SESSION"
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false)
        
        let request = UNNotificationRequest(
            identifier: notificationIdentifier,
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Logger.warning("Failed to update notification: \(error.localizedDescription)", category: "NotificationManager")
            }
        }
    }
    
    /// Remove the persistent notification
    func removeActiveSessionNotification() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        Logger.debug("Active session notification removed", category: "NotificationManager")
    }
    
    /// Show notification to bring app to foreground for recording
    func showRecordingRequestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "VoiceInk Recording"
        content.body = "Tap to start recording"
        content.sound = .default
        content.categoryIdentifier = "RECORDING_REQUEST"
        content.userInfo = ["action": "startRecording"]
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        
        let request = UNNotificationRequest(
            identifier: "com.asterayx.VoiceInk.recordingRequest",
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Logger.error("Failed to show recording request notification: \(error.localizedDescription)", category: "NotificationManager")
            } else {
                Logger.info("Recording request notification shown", category: "NotificationManager")
            }
        }
    }
}

