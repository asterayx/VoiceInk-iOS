//
//  AudioSessionManager.swift
//  VoiceInk-ios
//
//  Manages audio session lifecycle with configurable timeout
//  Prevents "session activation failed" errors by keeping session active between recordings
//

import Foundation
import Combine
import AVFoundation
import UIKit

@MainActor
final class AudioSessionManager: ObservableObject {
    static let shared = AudioSessionManager()
    
    @Published var isSessionActive: Bool = false
    @Published var timeoutRemaining: TimeInterval = 0
    
    private var deactivationTimer: Timer?
    private let settings = AppSettings.shared
    
    private init() {}
    
    // MARK: - Public Interface
    
    /// Activates audio session for recording with optimal settings
    func activateSessionForRecording() async throws {
        // Check if app is in foreground - audio session activation can fail in background
        let appState = UIApplication.shared.applicationState
        guard appState == .active else {
            let error = NSError(
                domain: "com.asterayx.VoiceInk.AudioSessionManager",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Cannot activate audio session - app must be in foreground"]
            )
            Logger.error("Cannot activate audio session - app state is \(appState.rawValue) (0=active, 1=inactive, 2=background)", category: "AudioSessionManager")
            throw error
        }
        
        let audioSession = AVAudioSession.sharedInstance()
        
        do {
            // First, try to deactivate if already active (to reset state)
            // This helps avoid activation conflicts
            if isSessionActive {
                do {
                    try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                    Logger.debug("Deactivated existing session before reactivation", category: "AudioSessionManager")
                } catch {
                    // Ignore deactivation errors - session might not be active
                    Logger.debug("Could not deactivate (session may not be active): \(error.localizedDescription)", category: "AudioSessionManager")
                }
            }
            
            // Configure session for recording with background support
            // Note: .mixWithOthers allows other audio apps to play, but may reduce recording quality
            // For better recording quality, consider removing .mixWithOthers if not needed
            // .defaultToSpeaker ensures audio plays through speaker when headphones aren't connected
            // .allowBluetooth and .allowBluetoothA2DP enable Bluetooth audio devices
            try audioSession.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .mixWithOthers]
            )
            
            // Small delay to ensure category is set before activation (non-blocking)
            try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
            
            // Activate the session
            // Use .notifyOthersOnDeactivation to properly handle conflicts
            try audioSession.setActive(true, options: [.notifyOthersOnDeactivation])
            
            isSessionActive = true
            cancelScheduledDeactivation()
            
            Logger.info("Audio session activated for recording", category: "AudioSessionManager")
            
        } catch let error as NSError {
            Logger.warning("Audio session activation failed: \(error.localizedDescription) (Code: \(error.code))", category: "AudioSessionManager")
            
            // Expand error handling to cover more activation failure cases
            // Common error codes:
            // 561015905 = '!act' - Session activation failed (usually due to another app using audio)
            // 561017449 = '!act' - Session activation failed (variant, another app using audio or timing issue)
            // 560030580 = '!cat' - Category not set or invalid
            // 560161140 = '!fmt' - Format not supported
            let retryableErrorCodes: [Int] = [561015905, 561017449, 560030580] // Session activation and category errors
            
            if retryableErrorCodes.contains(error.code) {
                Logger.debug("Retrying activation after failure (error code: \(error.code))", category: "AudioSessionManager")
                
                // For activation errors (561015905, 561017449), use longer delay and more aggressive reset
                let isActivationError = error.code == 561015905 || error.code == 561017449
                let retryDelay: UInt64 = isActivationError ? 200_000_000 : 100_000_000 // 0.2s for activation errors, 0.1s for others
                
                do {
                    // For activation errors, try more aggressive deactivation
                    if isActivationError {
                        // First, try to deactivate with notifyOthersOnDeactivation
                        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                        
                        // Then try again without options to force deactivation
                        try? audioSession.setActive(false)
                        try? await Task.sleep(nanoseconds: retryDelay)
                    } else {
                        // For other errors, simpler deactivation
                        try? audioSession.setActive(false)
                        try? await Task.sleep(nanoseconds: retryDelay)
                    }
                    
                    // Re-set category in case it was the issue
                    if error.code == 560030580 {
                        try audioSession.setCategory(
                            .playAndRecord,
                            mode: .spokenAudio,
                            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .mixWithOthers]
                        )
                        try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
                    }
                    
                    // Try activating again
                    try audioSession.setActive(true, options: [.notifyOthersOnDeactivation])
                    isSessionActive = true
                    cancelScheduledDeactivation()
                    Logger.info("Session activated on retry", category: "AudioSessionManager")
                    return // Success, exit the function
                } catch let retryError {
                    Logger.error("Retry also failed: \(retryError.localizedDescription) (Code: \((retryError as NSError).code))", category: "AudioSessionManager")
                    isSessionActive = false
                    
                    // For activation errors, provide user-friendly message
                    let errorMessage: String
                    if isActivationError {
                        errorMessage = "Another app is using the microphone. Please close other audio apps and try again."
                    } else {
                        errorMessage = "Audio session activation failed after retry: \(retryError.localizedDescription). Original error: \(error.localizedDescription)"
                    }
                    
                    // Provide more context in the error
                    let enhancedError = NSError(
                        domain: error.domain,
                        code: error.code,
                        userInfo: [
                            NSLocalizedDescriptionKey: errorMessage,
                            NSUnderlyingErrorKey: retryError
                        ]
                    )
                    throw enhancedError
                }
            } else {
                // Non-retryable error - log and throw with context
                Logger.error("Audio session activation failed with non-retryable error: \(error.localizedDescription) (Code: \(error.code))", category: "AudioSessionManager")
                isSessionActive = false
                throw error
            }
        }
    }
    
    /// Schedules session deactivation after configured timeout
    /// Thread-safe: Atomically cancels existing timer before creating new one
    func scheduleDeactivation() {
        // Atomically cancel existing timer before creating new one to prevent race conditions
        let oldTimer = deactivationTimer
        deactivationTimer = nil
        oldTimer?.invalidate()
        
        let timeoutSeconds = settings.audioSessionTimeoutSeconds
        
        // If timeout is 0, deactivate immediately (legacy behavior)
        guard timeoutSeconds > 0 else {
            deactivateSession()
            return
        }
        
        timeoutRemaining = TimeInterval(timeoutSeconds)
        
        // Optimized timer: use RunLoop.main for proper scheduling and ensure cleanup
        let newTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                
                self.timeoutRemaining -= 1
                
                // Update notification with remaining time if in keyboard mode
                let coordinator = AppGroupCoordinator.shared
                if coordinator.isActivated && self.timeoutRemaining > 0 {
                    NotificationManager.shared.updateNotification(timeRemaining: self.timeoutRemaining)
                }
                
                if self.timeoutRemaining <= 0 {
                    self.deactivateSession()
                }
            }
        }
        deactivationTimer = newTimer
        RunLoop.main.add(newTimer, forMode: .common)
        
        Logger.debug("Audio session deactivation scheduled in \(timeoutSeconds) seconds", category: "AudioSessionManager")
    }
    
    /// Extends the timeout period (called when new recording starts)
    /// In keyboard mode, extends to 10 minutes (600 seconds)
    /// Also ensures session is active (reactivates if needed, but only if app is in foreground)
    func extendTimeout() {
        // If session is not active, try to reactivate it
        // BUT: Only if app is in foreground (background activation will fail)
        if !isSessionActive {
            // Check if app is in foreground by checking application state
            let appState = UIApplication.shared.applicationState
            if appState == .active {
                Logger.warning("Session not active during extendTimeout, reactivating (app is active)", category: "AudioSessionManager")
                Task {
                    do {
                        try await activateSessionForRecording()
                        Logger.info("Session reactivated successfully", category: "AudioSessionManager")
                    } catch {
                        Logger.error("Failed to reactivate session: \(error.localizedDescription)", category: "AudioSessionManager")
                    }
                }
            } else {
                Logger.warning("Session not active but app is in background - cannot reactivate", category: "AudioSessionManager")
            }
        }
        
        guard isSessionActive else {
            Logger.warning("Cannot extend timeout - session is not active", category: "AudioSessionManager")
            return
        }
        
        // Check if we're in keyboard mode (activated session)
        // Cache the value to prevent race conditions from state changes
        let coordinator = AppGroupCoordinator.shared
        let isKeyboardMode = coordinator.isActivated
        
        if isKeyboardMode {
            // For keyboard mode, use 10-minute timeout
            // Use local variable instead of modifying settings to prevent race conditions
            let keyboardTimeout = 600
            let originalTimeout = settings.audioSessionTimeoutSeconds
            settings.audioSessionTimeoutSeconds = keyboardTimeout
            scheduleDeactivation()
            // Restore original timeout immediately to prevent concurrent access issues
            settings.audioSessionTimeoutSeconds = originalTimeout
            Logger.debug("Audio session timeout extended to 10 minutes (keyboard mode)", category: "AudioSessionManager")
        } else {
            // For normal mode, use configured timeout
            scheduleDeactivation()
            Logger.debug("Audio session timeout extended", category: "AudioSessionManager")
        }
    }
    
    /// Immediately deactivates the session
    func deactivateSession() {
        cancelScheduledDeactivation()
        
        guard isSessionActive else { return }
        
        // Check if this was a keyboard mode session
        let coordinator = AppGroupCoordinator.shared
        let wasKeyboardMode = coordinator.isActivated
        
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            isSessionActive = false
            timeoutRemaining = 0
            
            // If this was keyboard mode, update activation state
            if wasKeyboardMode {
                coordinator.updateActivationState(false)
                // Remove persistent notification
                NotificationManager.shared.removeActiveSessionNotification()
                Logger.info("Audio session deactivated (keyboard mode expired)", category: "AudioSessionManager")
            } else {
                Logger.info("Audio session deactivated", category: "AudioSessionManager")
            }
        } catch {
            Logger.warning("Failed to deactivate audio session: \(error.localizedDescription)", category: "AudioSessionManager")
        }
    }
    
    /// Force immediate deactivation (for app backgrounding, etc.)
    func forceDeactivate() {
        cancelScheduledDeactivation()
        
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            isSessionActive = false
            timeoutRemaining = 0
            Logger.info("Audio session force deactivated", category: "AudioSessionManager")
        } catch {
            Logger.warning("Failed to force deactivate audio session: \(error.localizedDescription)", category: "AudioSessionManager")
        }
    }
    
    // MARK: - Private Methods
    
    private func cancelScheduledDeactivation() {
        deactivationTimer?.invalidate()
        deactivationTimer = nil
        timeoutRemaining = 0
    }
    
    // MARK: - Debug Helpers
    
    var debugInfo: [String: Any] {
        return [
            "isSessionActive": isSessionActive,
            "timeoutRemaining": timeoutRemaining,
            "hasScheduledDeactivation": deactivationTimer != nil,
            "configuredTimeout": settings.audioSessionTimeoutSeconds
        ]
    }
}

// MARK: - App Lifecycle Integration

extension AudioSessionManager {
    
    /// Call when app enters background
    func handleAppDidEnterBackground() {
        // Optionally force deactivate when app backgrounds
        // This depends on whether you want background recording capability
        Logger.debug("App entered background - audio session state: \(isSessionActive)", category: "AudioSessionManager")
    }
    
    /// Call when app becomes active
    func handleAppDidBecomeActive() {
        Logger.debug("App became active - audio session state: \(isSessionActive)", category: "AudioSessionManager")
    }
    
    /// Call when app will terminate
    func handleAppWillTerminate() {
        forceDeactivate()
    }
}
