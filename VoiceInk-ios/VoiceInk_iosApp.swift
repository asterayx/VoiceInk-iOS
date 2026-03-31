//
//  VoiceInk_iosApp.swift
//  VoiceInk-ios
//
//  Created by Taafa D on 12/08/2025.
//

import SwiftUI
import SwiftData
import os.log

@main
struct VoiceInk_iosApp: App {
    private let logger = OSLog(subsystem: "com.asterayx.VoiceInk", category: "MainApp")
    @State private var hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    @StateObject private var recordingManager = RecordingManager()
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingURL: URL?
    
    // URL Scheme constants for validation
    private static let urlScheme = "voiceink"
    private static let validHosts = ["record", "stop", "activate"]
    
    init() {
        // Defer App Group access to avoid CFPrefsPlistSource warnings
        // Clear stale recording state after app has fully launched
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            AppGroupCoordinator.shared.updateRecordingState(false)
            Logger.debug("Cleared stale recording state on app launch", category: "VoiceInkApp")
        }
    }
    
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Transcription.self,
        ])
        
        // Configure ModelConfiguration to use app's own container instead of App Group
        // This prevents SwiftData from trying to use the App Group container
        // (Transcription data doesn't need to be shared with keyboard extension)
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        
        // Ensure Application Support directory exists
        if !FileManager.default.fileExists(atPath: appSupportURL.path) {
            do {
                try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true, attributes: nil)
                Logger.info("Created Application Support directory", category: "VoiceInkApp")
            } catch {
                Logger.warning("Failed to create Application Support directory: \(error.localizedDescription)", category: "VoiceInkApp")
                // Continue anyway - SwiftData will try to create it
            }
        }
        
        let storeURL = appSupportURL.appendingPathComponent("default.store")
        
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            return container
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                ContentView()
                    .environmentObject(recordingManager)
                    .onOpenURL { url in
                        handleURL(url)
                    }
                    .onChange(of: scenePhase) { oldPhase, newPhase in
                        handleScenePhaseChange(from: oldPhase, to: newPhase)
                    }
            } else {
                OnboardingView(isOnboardingComplete: $hasCompletedOnboarding)
                    .onOpenURL { url in
                        handleURL(url)
                    }
            }
        }
        .modelContainer(sharedModelContainer)
    }
    
    private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        if newPhase == .active && oldPhase != .active {
            Logger.debug("App became active (from \(oldPhase) to \(newPhase))", category: "VoiceInkApp")
            os_log("📱 App: Became active", log: logger, type: .info)
            
            // Priority 1: If we have a pending URL action, process it first (URL scheme takes precedence)
            if let url = pendingURL {
                Logger.debug("Processing pending URL now that app is active", category: "VoiceInkApp")
                os_log("📱 App: Processing pending URL: %{public}@", log: logger, type: .info, url.absoluteString)
                pendingURL = nil
                // App is now active, process directly with a small delay to ensure everything is ready
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.processURL(url, skipWait: true)
                }
                // Don't check App Group flags if we have a pending URL - URL will handle it
                return
            }
            
            // Priority 2: Check App Group requests (PRIMARY method on iOS 15+)
            // iOS 15+ blocks keyboard extensions from automatically opening apps
            // Solution: Keyboard sets App Group flag, app checks flag when it becomes active
            // This is the Apple-compliant architecture used by Gboard, SwiftKey, etc.
            let coordinator = AppGroupCoordinator.shared
            
            // Check for start recording request (from keyboard) - this is the PRIMARY method
            if coordinator.checkAndConsumeStartRecordingFlag() {
                Logger.debug("Found pending recording request from keyboard (App Group flag)", category: "VoiceInkApp")
                os_log("🎙️ App: Found pending recording request - starting recording flow automatically", log: logger, type: .info)
                
                // Start recording flow automatically - user came from keyboard
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard !self.recordingManager.isRecording else {
                        Logger.warning("Already recording, ignoring duplicate request", category: "VoiceInkApp")
                        return
                    }
                    Logger.debug("Auto-starting recording (user came from keyboard)", category: "VoiceInkApp")
                    self.recordingManager.startRecordingFlow()
                }
                return
            }
            
            // Check for stop recording request (from keyboard)
            if coordinator.checkAndConsumeStopRecordingFlag() {
                Logger.debug("Found stop recording flag, processing", category: "VoiceInkApp")
                os_log("🛑 App: Found stop recording flag", log: logger, type: .info)
                if recordingManager.isRecording {
                    NotificationCenter.default.post(name: .stopRecordingFromKeyboard, object: nil)
                }
            }
        }
    }
    
    /// Wait for app to become fully active before executing action
    /// This ensures record() can be called successfully
    private func waitForAppToBecomeActive(completion: @escaping () -> Void) {
        let appState = UIApplication.shared.applicationState
        Logger.debug("Current app state: \(appState.rawValue) (0=active, 1=inactive, 2=background)", category: "VoiceInkApp")
        
        if appState == .active {
            // App is already active, execute after a small delay to ensure everything is ready
            Logger.debug("App is already active, executing after short delay", category: "VoiceInkApp")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                completion()
            }
            return
        }
        
        // App is not yet active, wait for it to become active
        // Use a notification observer for cleaner approach
        Logger.debug("App not yet active, waiting for didBecomeActiveNotification", category: "VoiceInkApp")
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            if let observer = observer {
                NotificationCenter.default.removeObserver(observer)
            }
            Logger.debug("App became active, executing action", category: "VoiceInkApp")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                completion()
            }
        }
        
        // Fallback: If app doesn't become active within 2 seconds, execute anyway
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if let observer = observer {
                NotificationCenter.default.removeObserver(observer)
                Logger.warning("Timeout waiting for app to become active, executing anyway", category: "VoiceInkApp")
                completion()
            }
        }
    }
    
    private func handleURL(_ url: URL) {
        Logger.debug("Received URL: \(url.absoluteString)", category: "VoiceInkApp")
        os_log("📩 App: Received URL: %{public}@", log: logger, type: .info, url.absoluteString)
        
        // Validate URL scheme
        guard let scheme = url.scheme, scheme == Self.urlScheme else {
            Logger.warning("URL scheme mismatch, expected '\(Self.urlScheme)', got '\(url.scheme ?? "nil")'", category: "VoiceInkApp")
            return
        }
        
        // Validate URL host
        guard let host = url.host, Self.validHosts.contains(host) else {
            Logger.warning("Invalid URL host: '\(url.host ?? "nil")'. Valid hosts: \(Self.validHosts)", category: "VoiceInkApp")
            return
        }
        
        Logger.debug("URL validated - scheme: \(scheme), host: \(host)", category: "VoiceInkApp")
        
        let appState = UIApplication.shared.applicationState
        Logger.debug("Current app state: \(appState.rawValue) (0=active, 1=inactive, 2=background)", category: "VoiceInkApp")
        
        // If app is not yet active, store URL and process when app becomes active
        if appState != .active {
            Logger.debug("App not yet active, storing URL for later processing", category: "VoiceInkApp")
            pendingURL = url
            return
        }
        
        // App is active, process URL immediately
        processURL(url)
    }
    
    private func processURL(_ url: URL, skipWait: Bool = false) {
        Logger.debug("Processing URL: \(url.absoluteString), skipWait: \(skipWait)", category: "VoiceInkApp")
        
        // Helper to execute action (with or without wait)
        let executeAction: (@escaping () -> Void) -> Void = { action in
            if skipWait {
                // Already waited, execute directly
                action()
            } else {
                // Need to wait for app to be active
                self.waitForAppToBecomeActive {
                    action()
                }
            }
        }
        
        // Simplified: Direct action handling - app is now in foreground
        // Host is already validated in handleURL()
        guard let host = url.host else {
            Logger.error("URL host is nil after validation - this should not happen", category: "VoiceInkApp")
            return
        }
        
        switch host {
        case "record":
            Logger.debug("Starting recording (app opened from keyboard)", category: "VoiceInkApp")
            executeAction {
                // Prevent duplicate starts - check if already recording or starting
                guard !self.recordingManager.isRecording else {
                    Logger.warning("Already recording, ignoring duplicate request", category: "VoiceInkApp")
                    return
                }
                
                // Verify app is actually in foreground before starting
                let appState = UIApplication.shared.applicationState
                guard appState == .active else {
                    Logger.warning("App is not active (state: \(appState.rawValue)), waiting", category: "VoiceInkApp")
                    // Wait a bit more and try again
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        // Double-check state before starting
                        guard !self.recordingManager.isRecording else {
                            Logger.warning("Already recording after wait, ignoring", category: "VoiceInkApp")
                            return
                        }
                        if UIApplication.shared.applicationState == .active {
                            self.recordingManager.startRecordingFlow()
                        } else {
                            Logger.error("App still not active, cannot start recording", category: "VoiceInkApp")
                        }
                    }
                    return
                }
                
                // Note: Flag is already consumed in handleScenePhaseChange() if app was activated that way
                // If we got here via URL scheme, the flag may not have been set, so we check but don't require it
                // Start recording flow (flag consumption is idempotent, so safe to call)
                self.recordingManager.startRecordingFlow()
                // App stays in foreground - user can manually switch back to keyboard
            }
            
        case "stop":
            // Stop requests should now come via App Group, not URL scheme
            // But handle it here as a fallback
            Logger.debug("Stop URL received (should use App Group instead)", category: "VoiceInkApp")
            if recordingManager.isRecording {
                NotificationCenter.default.post(name: .stopRecordingFromKeyboard, object: nil)
            }
            // Don't send to background - let user manually switch back to keyboard
            
        case "activate":
            Logger.debug("Activation requested (app opened from keyboard)", category: "VoiceInkApp")
            executeAction {
                let coordinator = AppGroupCoordinator.shared
                if let callback = coordinator.onActivationRequested {
                    callback()
                }
                // App stays in foreground - user can manually switch back to keyboard
            }
            
        default:
            Logger.warning("Unknown URL host: \(url.host ?? "nil")", category: "VoiceInkApp")
            break
        }
    }
    
}
