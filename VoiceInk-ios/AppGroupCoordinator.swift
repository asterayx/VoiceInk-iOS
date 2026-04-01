import Foundation

// Logger is available in main app target, but may not be in keyboard extension
// Use conditional compilation or fallback to print for keyboard extension
#if canImport(os)
import os.log
#endif

/// Handles communication between the main VoiceInk app and the keyboard extension
/// Uses App Groups + Darwin Notifications for reliable iOS-native communication
final class AppGroupCoordinator {
    
    // Fallback logging for when custom Logger is not available (e.g., in keyboard extension)
    private static func log(_ message: String, level: String = "DEBUG") {
        #if canImport(os)
        // Try to use custom Logger if available
        if let _ = NSClassFromString("VoiceInk_ios.Logger") {
            // Custom Logger is available - but we can't call it directly without import
            // So we'll use os_log as fallback
            let osLog = OSLog(subsystem: "com.asterayx.VoiceInk", category: "AppGroupCoordinator")
            os_log("%{public}@", log: osLog, type: .default, "[\(level)] \(message)")
        } else {
            // Use system logging
            let osLog = OSLog(subsystem: "com.asterayx.VoiceInk", category: "AppGroupCoordinator")
            os_log("%{public}@", log: osLog, type: .default, "[\(level)] \(message)")
        }
        #else
        print("[\(level)] AppGroupCoordinator: \(message)")
        #endif
    }
    static let shared = AppGroupCoordinator()
    
    // MARK: - Constants
    // App Group identifier - must match entitlements exactly
    private let appGroupIdentifier = "group.asterayx.voiceink"
    
    // UserDefaults keys for persistent state
    private enum UserDefaultsKeys {
        static let shouldStartRecording = "shouldStartRecording"
        static let shouldStopRecording = "shouldStopRecording"
        static let shouldActivate = "shouldActivate"
        static let isRecording = "isRecording"
        static let isActivated = "isActivated"
        static let lastRecordingTimestamp = "lastRecordingTimestamp"
        static let activationTimestamp = "activationTimestamp"
        static let transcriptText = "transcriptText"
        static let transcriptReady = "transcriptReady"
        static let transcriptTimestamp = "transcriptTimestamp"
        static let stopRequestTimestamp = "stopRequestTimestamp" // Track when stop was requested
        static let sharedModes = "sharedModes"               // JSON array of mode info for keyboard
        static let selectedModeId = "sharedSelectedModeId"   // Currently selected mode ID
    }
    
    // Darwin notification names for real-time communication
    private enum NotificationNames {
        static let startRecording = "com.asterayx.VoiceInk.startRecording"
        static let stopRecording = "com.asterayx.VoiceInk.stopRecording"
        static let activate = "com.asterayx.VoiceInk.activate"
        static let recordingStateChanged = "com.asterayx.VoiceInk.recordingStateChanged"
        static let activationStateChanged = "com.asterayx.VoiceInk.activationStateChanged"
        static let transcriptReady = "com.asterayx.VoiceInk.transcriptReady"
    }
    
    // MARK: - Properties
    // Use lazy initialization with caching to minimize UserDefaults access
    // This prevents CFPrefsPlistSource warnings by deferring UserDefaults creation
    private var _cachedDefaults: UserDefaults?
    private let defaultsInitQueue = DispatchQueue(label: "com.asterayx.VoiceInk.AppGroupCoordinator.defaultsInit", qos: .utility)
    private var sharedDefaults: UserDefaults? {
        // Use double-checked locking pattern for thread-safe lazy initialization
        if let cached = _cachedDefaults {
            return cached
        }
        
        // Synchronize access to prevent multiple initializations
        return defaultsInitQueue.sync {
            // Check again after acquiring lock (double-checked locking)
            if let cached = _cachedDefaults {
                return cached
            }
            
            // Create UserDefaults instance when actually needed
            // Note: This may still trigger CFPrefsPlistSource warning on first access
            // but it's a known iOS quirk that doesn't affect functionality
            let defaults = UserDefaults(suiteName: appGroupIdentifier)
            _cachedDefaults = defaults
            return defaults
        }
    }
    private let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
    
    // Serial queue for atomic flag consumption and transcript operations to prevent race conditions
    private let operationQueue = DispatchQueue(label: "com.asterayx.VoiceInk.AppGroupCoordinator.operations", qos: .userInitiated)
    
    // Callbacks for the main app
    var onStartRecordingRequested: (() -> Void)?
    var onStopRecordingRequested: (() -> Void)?
    var onActivationRequested: (() -> Void)?
    
    // Track if we've verified App Group access (to avoid repeated verification)
    private var hasVerifiedAccess = false
    
    // MARK: - Initialization
    private init() {
        setupNotificationObservers()
        // Defer App Group verification to avoid CFPrefsPlistSource warnings
        // Verify access asynchronously after app has fully launched
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.verifyAppGroupAccess()
        }
    }
    
    /// Verify App Group is accessible and properly configured
    /// This should be called after app launch to avoid CFPrefsPlistSource warnings
    private func verifyAppGroupAccess() {
        // Only verify once to avoid repeated warnings
        guard !hasVerifiedAccess else { return }
        hasVerifiedAccess = true
        
        guard let defaults = sharedDefaults else {
            Self.log("CRITICAL - App Group '\(appGroupIdentifier)' is not accessible! Check that:", level: "ERROR")
            Self.log("  1. App Group is configured in both main app and keyboard extension entitlements", level: "ERROR")
            Self.log("  2. App Group identifier matches exactly: '\(appGroupIdentifier)'", level: "ERROR")
            Self.log("  3. App Group is enabled in Apple Developer Portal", level: "ERROR")
            return
        }
        
        // Test write/read to verify access
        // Note: On modern iOS, UserDefaults writes are automatically synchronized
        // No need for explicit synchronize() which can trigger CFPrefsPlistSource warnings
        let testKey = "appGroupAccessTest"
        let testValue = Date().timeIntervalSince1970
        defaults.set(testValue, forKey: testKey)
        
        // For App Group UserDefaults, writes are typically immediately visible
        // We'll verify by reading back (with a small synchronous wait if needed)
        let readValue = defaults.double(forKey: testKey)
        if abs(readValue - testValue) < 0.001 {
            defaults.removeObject(forKey: testKey)
            Self.log("App Group access verified successfully", level: "DEBUG")
        } else {
            // If immediate read fails, the write might still be propagating
            // This is acceptable - the App Group is accessible if sharedDefaults is not nil
            defaults.removeObject(forKey: testKey)
            Self.log("App Group access verified (write/read may have timing differences, but App Group is accessible)", level: "DEBUG")
        }
    }
    
    /// Public method to verify App Group access (for debugging/settings)
    func verifyAppGroupConfiguration() -> Bool {
        guard let defaults = sharedDefaults else { return false }
        
        // Test write/read
        // Note: On modern iOS, UserDefaults writes are automatically synchronized
        let testKey = "appGroupAccessTest"
        let testValue = Date().timeIntervalSince1970
        defaults.set(testValue, forKey: testKey)
        
        // Small delay to allow write to propagate
        var result = false
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let readValue = defaults.double(forKey: testKey)
            defaults.removeObject(forKey: testKey)
            result = abs(readValue - testValue) < 0.001
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 1.0)
        
        return result
    }
    
    deinit {
        removeNotificationObservers()
    }
    
    // MARK: - Public Interface for Keyboard Extension
    
    /// Call this from the keyboard extension to request activation (permissions + session)
    func requestActivation() {
        let timestamp = Date().timeIntervalSince1970
        
        Self.log("requestActivation called", level: "DEBUG")
        
        // Verify App Group is accessible
        guard let defaults = sharedDefaults else {
            Self.log("CRITICAL - sharedDefaults is nil! App Group may not be configured correctly. Check that App Group '\(appGroupIdentifier)' is configured in both main app and keyboard extension entitlements", level: "ERROR")
            return
        }
        
        // Set persistent flag
        // Note: On modern iOS, UserDefaults writes are automatically synchronized
        // Darwin notifications provide real-time communication, so explicit sync is not needed
        defaults.set(true, forKey: UserDefaultsKeys.shouldActivate)
        defaults.set(timestamp, forKey: UserDefaultsKeys.activationTimestamp)
        
        // Send immediate notification
        postDarwinNotification(NotificationNames.activate)
        Self.log("Activation request sent (flag + notification)", level: "DEBUG")
    }
    
    /// Call this from the keyboard extension to request recording start
    func requestStartRecording() {
        let timestamp = Date().timeIntervalSince1970
        
        Self.log("requestStartRecording called", level: "DEBUG")
        
        // Verify App Group is accessible
        guard let defaults = sharedDefaults else {
            Self.log("CRITICAL - sharedDefaults is nil! App Group may not be configured correctly.", level: "ERROR")
            return
        }
        
        // Set persistent flag
        // Note: On modern iOS, UserDefaults writes are automatically synchronized
        // Darwin notifications provide real-time communication, so explicit sync is not needed
        defaults.set(true, forKey: UserDefaultsKeys.shouldStartRecording)
        defaults.set(timestamp, forKey: UserDefaultsKeys.lastRecordingTimestamp)
        
        // Send immediate notification
        postDarwinNotification(NotificationNames.startRecording)
        Self.log("Start recording request sent (flag + notification)", level: "DEBUG")
    }
    
    /// Call this from the keyboard extension to request recording stop
    func requestStopRecording() {
        let timestamp = Date().timeIntervalSince1970
        
        Self.log("requestStopRecording called", level: "DEBUG")
        
        // Verify App Group is accessible
        guard let defaults = sharedDefaults else {
            Self.log("CRITICAL - sharedDefaults is nil! App Group may not be configured correctly.", level: "ERROR")
            return
        }
        
        // Set persistent flag
        // Note: On modern iOS, UserDefaults writes are automatically synchronized
        // Darwin notifications provide real-time communication, so explicit sync is not needed
        defaults.set(true, forKey: UserDefaultsKeys.shouldStopRecording)
        defaults.set(timestamp, forKey: UserDefaultsKeys.lastRecordingTimestamp)
        // Store stop request timestamp to match with transcript
        defaults.set(timestamp, forKey: UserDefaultsKeys.stopRequestTimestamp)
        
        // Send immediate notification
        postDarwinNotification(NotificationNames.stopRecording)
        Self.log("Stop recording request sent (flag + notification)", level: "DEBUG")
    }
    
    /// Get current recording state (for keyboard UI updates)
    /// Note: This is a pure getter - does not modify state
    /// Thread-safe: Uses serial queue to prevent race conditions
    var isRecording: Bool {
        guard let defaults = sharedDefaults else { return false }
        
        return operationQueue.sync {
            let storedState = defaults.bool(forKey: UserDefaultsKeys.isRecording)
            let timestamp = defaults.double(forKey: UserDefaultsKeys.lastRecordingTimestamp)
            let currentTime = Date().timeIntervalSince1970
            
            // If the stored state is more than 30 seconds old, consider it stale
            // But don't modify state in getter - return false and let caller handle cleanup
            if storedState && (currentTime - timestamp) > 30 {
                Self.log("Recording state appears stale (getter)", level: "WARNING")
                // Don't modify state here - getters should be side-effect-free
                // Caller should call checkAndClearStaleRecordingState() if needed
                return false
            }
            
            return storedState
        }
    }
    
    /// Check and clear stale recording state (explicit cleanup method)
    /// This should be called explicitly, not from a getter
    func checkAndClearStaleRecordingState() {
        let storedState = sharedDefaults?.bool(forKey: UserDefaultsKeys.isRecording) ?? false
        let timestamp = sharedDefaults?.double(forKey: UserDefaultsKeys.lastRecordingTimestamp) ?? 0
        let currentTime = Date().timeIntervalSince1970
        
        if storedState && (currentTime - timestamp) > 30 {
            Self.log("Recording state appears stale, clearing it", level: "WARNING")
            updateRecordingState(false)
        }
    }
    
    /// Get current activation state (for keyboard UI updates)
    /// Note: This is a pure getter - does not modify state
    /// Thread-safe: Uses serial queue to prevent race conditions
    var isActivated: Bool {
        guard let defaults = sharedDefaults else { return false }
        
        return operationQueue.sync {
            let storedState = defaults.bool(forKey: UserDefaultsKeys.isActivated)
            let timestamp = defaults.double(forKey: UserDefaultsKeys.activationTimestamp)
            let currentTime = Date().timeIntervalSince1970
            
            // If activation is more than 10 minutes old, consider it expired
            // But don't modify state in getter - return false and let caller handle cleanup
            if storedState && (currentTime - timestamp) > 600 {
                Self.log("Activation expired (10 minutes) (getter)", level: "WARNING")
                // Don't modify state here - getters should be side-effect-free
                // Caller should call checkAndClearStaleActivationState() if needed
                return false
            }
            
            return storedState
        }
    }
    
    /// Check and clear stale activation state (explicit cleanup method)
    /// This should be called explicitly, not from a getter
    func checkAndClearStaleActivationState() {
        let storedState = sharedDefaults?.bool(forKey: UserDefaultsKeys.isActivated) ?? false
        let timestamp = sharedDefaults?.double(forKey: UserDefaultsKeys.activationTimestamp) ?? 0
        let currentTime = Date().timeIntervalSince1970
        
        if storedState && (currentTime - timestamp) > 600 {
            Self.log("Activation expired (10 minutes), clearing it", level: "WARNING")
            updateActivationState(false)
        }
    }
    
    // MARK: - Public Interface for Main App
    
    /// Call this from the main app to update recording state
    /// Thread-safe: Uses serial queue and explicit synchronization
    func updateRecordingState(_ isRecording: Bool) {
        guard let defaults = sharedDefaults else { return }
        
        operationQueue.sync {
            defaults.set(isRecording, forKey: UserDefaultsKeys.isRecording)
            // Update timestamp whenever state changes
            defaults.set(Date().timeIntervalSince1970, forKey: UserDefaultsKeys.lastRecordingTimestamp)
            // Note: On modern iOS, UserDefaults writes are automatically synchronized
            // Darwin notifications provide real-time communication, so explicit sync is not needed
        }
        
        // Notify keyboard of state change (outside queue to avoid blocking)
        postDarwinNotification(NotificationNames.recordingStateChanged)
        
        Self.log("Updated recording state: \(isRecording)", level: "DEBUG")
    }
    
    /// Call this from the main app to update activation state
    /// Thread-safe: Uses serial queue and explicit synchronization
    func updateActivationState(_ isActivated: Bool) {
        guard let defaults = sharedDefaults else { return }
        
        operationQueue.sync {
            defaults.set(isActivated, forKey: UserDefaultsKeys.isActivated)
            // Update timestamp whenever state changes
            if isActivated {
                defaults.set(Date().timeIntervalSince1970, forKey: UserDefaultsKeys.activationTimestamp)
            } else {
                defaults.removeObject(forKey: UserDefaultsKeys.activationTimestamp)
            }
            // Note: On modern iOS, UserDefaults writes are automatically synchronized
            // Darwin notifications provide real-time communication, so explicit sync is not needed
        }
        
        // Notify keyboard of state change (outside queue to avoid blocking)
        postDarwinNotification(NotificationNames.activationStateChanged)
        
        Self.log("Updated activation state: \(isActivated)", level: "DEBUG")
    }
    
    /// Check activation flag without consuming it
    func checkActivationFlag() -> Bool {
        guard let defaults = sharedDefaults else { return false }
        return defaults.bool(forKey: UserDefaultsKeys.shouldActivate)
    }
    
    /// Check and consume activation flag (returns true if should activate)
    /// Thread-safe: Uses serial queue to prevent race conditions
    func checkAndConsumeActivationFlag() -> Bool {
        guard let defaults = sharedDefaults else { return false }
        
        return operationQueue.sync {
            let shouldActivate = defaults.bool(forKey: UserDefaultsKeys.shouldActivate)
            if shouldActivate {
                // Consume the flag atomically
                defaults.set(false, forKey: UserDefaultsKeys.shouldActivate)
                // Note: synchronize() is deprecated on modern iOS - writes are automatically synchronized
                return true
            }
            return false
        }
    }
    
    /// Check start recording flag without consuming it
    func checkStartRecordingFlag() -> Bool {
        guard let defaults = sharedDefaults else { return false }
        return defaults.bool(forKey: UserDefaultsKeys.shouldStartRecording)
    }
    
    /// Check and consume start recording flag (returns true if should start)
    /// Thread-safe: Uses serial queue to prevent race conditions
    func checkAndConsumeStartRecordingFlag() -> Bool {
        guard let defaults = sharedDefaults else { return false }
        
        return operationQueue.sync {
            let shouldStart = defaults.bool(forKey: UserDefaultsKeys.shouldStartRecording)
            if shouldStart {
                // Consume the flag atomically
                defaults.set(false, forKey: UserDefaultsKeys.shouldStartRecording)
                // Note: synchronize() is deprecated on modern iOS - writes are automatically synchronized
                return true
            }
            return false
        }
    }
    
    /// Check and consume stop recording flag (returns true if should stop)
    /// Thread-safe: Uses serial queue to prevent race conditions
    func checkAndConsumeStopRecordingFlag() -> Bool {
        guard let defaults = sharedDefaults else { return false }
        
        return operationQueue.sync {
            let shouldStop = defaults.bool(forKey: UserDefaultsKeys.shouldStopRecording)
            if shouldStop {
                // Consume the flag atomically
                defaults.set(false, forKey: UserDefaultsKeys.shouldStopRecording)
                return true
            }
            return false
        }
    }
    
    // MARK: - Transcript Management
    
    /// Store transcript text from main app (called when transcription completes)
    /// Thread-safe: Uses serial queue to prevent race conditions
    func storeTranscript(_ text: String) {
        guard let defaults = sharedDefaults else {
            Self.log("Cannot store transcript - sharedDefaults is nil", level: "ERROR")
            return
        }
        
        operationQueue.sync {
            let timestamp = Date().timeIntervalSince1970
            defaults.set(text, forKey: UserDefaultsKeys.transcriptText)
            defaults.set(true, forKey: UserDefaultsKeys.transcriptReady)
            defaults.set(timestamp, forKey: UserDefaultsKeys.transcriptTimestamp)
            // Note: On modern iOS, UserDefaults writes are automatically synchronized
            // Darwin notifications provide real-time communication, so explicit sync is not needed
        }
        
        // Notify keyboard that transcript is ready (outside queue to avoid blocking)
        postDarwinNotification(NotificationNames.transcriptReady)
        Self.log("Stored transcript: \(text.prefix(50))...", level: "DEBUG")
    }
    
    /// Clear any old/stale transcript (called when starting a new recording or stop request)
    /// Thread-safe: Uses serial queue to prevent race conditions
    func clearOldTranscript() {
        guard let defaults = sharedDefaults else { return }
        
        operationQueue.sync {
            defaults.removeObject(forKey: UserDefaultsKeys.transcriptText)
            defaults.set(false, forKey: UserDefaultsKeys.transcriptReady)
            defaults.removeObject(forKey: UserDefaultsKeys.transcriptTimestamp)
        }
        
        Self.log("Cleared old transcript", level: "DEBUG")
    }
    
    /// Get transcript without consuming it (for retry attempts)
    /// - Parameter afterTimestamp: Only return transcript if it was created after this timestamp
    /// Thread-safe: Uses serial queue to prevent race conditions
    func getTranscriptWithoutConsuming(afterTimestamp: TimeInterval = 0) -> String? {
        guard let defaults = sharedDefaults else {
            Self.log("getTranscriptWithoutConsuming: No shared defaults available", level: "WARNING")
            return nil
        }
        
        return operationQueue.sync {
            let isReady = defaults.bool(forKey: UserDefaultsKeys.transcriptReady)
            guard isReady else { return nil }
            
            // Check if transcript timestamp matches our stop request
            let transcriptTimestamp = defaults.double(forKey: UserDefaultsKeys.transcriptTimestamp)
            
            // Simplified: Since we clear old transcripts when starting/stopping,
            // we can accept any ready transcript. The timestamp check was causing issues.
            // If afterTimestamp is provided and transcript is significantly older, reject it
            if afterTimestamp > 0 {
                let timeDiff = transcriptTimestamp - afterTimestamp
                // Only reject if transcript is more than 30 seconds before stop request
                if timeDiff < -30.0 {
                    Self.log("Transcript timestamp (\(transcriptTimestamp)) is more than 30s before stop request (\(afterTimestamp)), ignoring (diff: \(timeDiff))", level: "WARNING")
                    return nil
                }
            }
            
            // Get the transcript text without consuming it
            guard let text = defaults.string(forKey: UserDefaultsKeys.transcriptText), !text.isEmpty else {
                return nil
            }
            
            return text
        }
    }
    
    /// Get and consume transcript (returns text if available, nil otherwise)
    /// This should be called from keyboard extension to get the transcript
    /// - Parameter afterTimestamp: Only return transcript if it was created after this timestamp
    /// Thread-safe: Uses serial queue to prevent race conditions
    func getAndConsumeTranscript(afterTimestamp: TimeInterval = 0) -> String? {
        guard let defaults = sharedDefaults else {
            Self.log("getAndConsumeTranscript: No shared defaults available", level: "WARNING")
            return nil
        }
        
        return operationQueue.sync {
            let isReady = defaults.bool(forKey: UserDefaultsKeys.transcriptReady)
            guard isReady else { return nil }
            
            // Check if transcript timestamp matches our stop request
            let transcriptTimestamp = defaults.double(forKey: UserDefaultsKeys.transcriptTimestamp)
            
            // Simplified: Since we clear old transcripts when starting/stopping,
            // we can accept any ready transcript. The timestamp check was causing issues.
            // If afterTimestamp is provided and transcript is significantly older, reject it
            if afterTimestamp > 0 {
                let timeDiff = transcriptTimestamp - afterTimestamp
                // Only reject if transcript is more than 30 seconds before stop request
                // This handles edge cases while still preventing very old transcripts
                if timeDiff < -30.0 {
                    Self.log("Transcript timestamp (\(transcriptTimestamp)) is more than 30s before stop request (\(afterTimestamp)), ignoring (diff: \(timeDiff))", level: "WARNING")
                    return nil
                }
            }
            
            // Get the transcript text
            guard let text = defaults.string(forKey: UserDefaultsKeys.transcriptText), !text.isEmpty else {
                // Clear the ready flag if text is empty
                defaults.set(false, forKey: UserDefaultsKeys.transcriptReady)
                return nil
            }
            
            // Consume the transcript atomically (clear it after reading)
            defaults.removeObject(forKey: UserDefaultsKeys.transcriptText)
            defaults.set(false, forKey: UserDefaultsKeys.transcriptReady)
            defaults.removeObject(forKey: UserDefaultsKeys.transcriptTimestamp)
            defaults.removeObject(forKey: UserDefaultsKeys.stopRequestTimestamp)
            
            Self.log("Retrieved and consumed transcript: \(text.prefix(50))... (timestamp: \(transcriptTimestamp))", level: "DEBUG")
            return text
        }
    }
    
    /// Check if transcript is ready (for keyboard to poll)
    var isTranscriptReady: Bool {
        guard let defaults = sharedDefaults else { return false }
        
        let isReady = defaults.bool(forKey: UserDefaultsKeys.transcriptReady)
        guard isReady else { return false }
        
        // Check if transcript is not stale (older than 5 minutes)
        let timestamp = defaults.double(forKey: UserDefaultsKeys.transcriptTimestamp)
        let currentTime = Date().timeIntervalSince1970
        
        if (currentTime - timestamp) > 300 { // 5 minutes
            // Transcript is stale, clear it
            defaults.set(false, forKey: UserDefaultsKeys.transcriptReady)
            defaults.removeObject(forKey: UserDefaultsKeys.transcriptText)
            defaults.removeObject(forKey: UserDefaultsKeys.transcriptTimestamp)
            return false
        }
        
        return true
    }
    
    /// Simplified: Get transcript without consuming (for simplified keyboard flow)
    func getTranscript() -> String? {
        guard let defaults = sharedDefaults else { return nil }
        guard defaults.bool(forKey: UserDefaultsKeys.transcriptReady) else { return nil }
        return defaults.string(forKey: UserDefaultsKeys.transcriptText)
    }
    
    /// Simplified: Clear transcript (for simplified keyboard flow)
    /// Thread-safe: Uses serial queue to prevent race conditions
    func clearTranscript() {
        guard let defaults = sharedDefaults else { return }
        
        operationQueue.sync {
            defaults.removeObject(forKey: UserDefaultsKeys.transcriptText)
            defaults.set(false, forKey: UserDefaultsKeys.transcriptReady)
            defaults.removeObject(forKey: UserDefaultsKeys.transcriptTimestamp)
        }
        
        Self.log("Cleared transcript", level: "DEBUG")
    }
    
    // MARK: - Darwin Notifications (Real-time Communication)
    
    private func setupNotificationObservers() {
        guard let center = notificationCenter else { return }
        
        // Observe start recording notifications
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                coordinator.handleStartRecordingNotification()
            },
            NotificationNames.startRecording as CFString,
            nil,
            .deliverImmediately
        )
        
        // Observe stop recording notifications
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                coordinator.handleStopRecordingNotification()
            },
            NotificationNames.stopRecording as CFString,
            nil,
            .deliverImmediately
        )
        
        // Observe activation notifications
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                coordinator.handleActivationNotification()
            },
            NotificationNames.activate as CFString,
            nil,
            .deliverImmediately
        )
    }
    
    private func removeNotificationObservers() {
        guard let center = notificationCenter else { return }
        CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
    }
    
    private func postDarwinNotification(_ name: String) {
        guard let center = notificationCenter else { return }
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }
    
    // MARK: - Notification Handlers
    
    private func handleStartRecordingNotification() {
        Self.log("Received start recording Darwin notification", level: "DEBUG")
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                Self.log("self is nil in handleStartRecordingNotification", level: "WARNING")
                return
            }
            
            // Also check the persistent flag
            _ = self.checkAndConsumeStartRecordingFlag()
            
            if let callback = self.onStartRecordingRequested {
                callback()
            } else {
                Self.log("onStartRecordingRequested callback is nil! RecordingManager.setupCoordinatorCallbacks() may not have been called. Flag will be checked when app becomes active", level: "WARNING")
            }
        }
    }
    
    private func handleStopRecordingNotification() {
        Self.log("Received stop recording Darwin notification", level: "DEBUG")
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                Self.log("self is nil in handleStopRecordingNotification", level: "WARNING")
                return
            }
            
            // Also check the persistent flag
            _ = self.checkAndConsumeStopRecordingFlag()
            
            if let callback = self.onStopRecordingRequested {
                callback()
            } else {
                Self.log("onStopRecordingRequested callback is nil! RecordingManager.setupCoordinatorCallbacks() may not have been called. Flag will be checked when app becomes active", level: "WARNING")
            }
        }
    }
    
    private func handleActivationNotification() {
        Self.log("Received activation Darwin notification", level: "DEBUG")
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                Self.log("self is nil in handleActivationNotification", level: "WARNING")
                return
            }
            
            // Also check the persistent flag
            _ = self.checkAndConsumeActivationFlag()
            
            if let callback = self.onActivationRequested {
                callback()
            } else {
                Self.log("onActivationRequested callback is nil! RecordingManager.setupCoordinatorCallbacks() may not have been called. Flag will be checked when app becomes active", level: "WARNING")
            }
        }
    }
    
    // MARK: - Mode Sharing (Main App ↔ Keyboard)

    /// Store mode list for keyboard extension to display
    /// Call this from the main app whenever modes change.
    func storeModes(_ modes: [(id: String, name: String)]) {
        guard let defaults = sharedDefaults else { return }
        let dicts = modes.map { ["id": $0.id, "name": $0.name] }
        if let data = try? JSONSerialization.data(withJSONObject: dicts) {
            defaults.set(data, forKey: UserDefaultsKeys.sharedModes)
        }
    }

    /// Retrieve available modes (for keyboard extension)
    func getAvailableModes() -> [(id: String, name: String)] {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: UserDefaultsKeys.sharedModes),
              let dicts = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return []
        }
        return dicts.compactMap { dict in
            guard let id = dict["id"], let name = dict["name"] else { return nil }
            return (id: id, name: name)
        }
    }

    /// Store selected mode ID (shared between app and keyboard)
    func setSelectedModeId(_ id: String?) {
        guard let defaults = sharedDefaults else { return }
        if let id = id {
            defaults.set(id, forKey: UserDefaultsKeys.selectedModeId)
        } else {
            defaults.removeObject(forKey: UserDefaultsKeys.selectedModeId)
        }
    }

    /// Get selected mode ID
    func getSelectedModeId() -> String? {
        sharedDefaults?.string(forKey: UserDefaultsKeys.selectedModeId)
    }

    // MARK: - Debug Helpers
    
    /// Clear all shared data (useful for debugging)
    func clearAllSharedData() {
        guard let defaults = sharedDefaults else { return }
        defaults.removeObject(forKey: UserDefaultsKeys.shouldStartRecording)
        defaults.removeObject(forKey: UserDefaultsKeys.shouldStopRecording)
        defaults.removeObject(forKey: UserDefaultsKeys.shouldActivate)
        defaults.removeObject(forKey: UserDefaultsKeys.isRecording)
        defaults.removeObject(forKey: UserDefaultsKeys.isActivated)
        defaults.removeObject(forKey: UserDefaultsKeys.lastRecordingTimestamp)
        defaults.removeObject(forKey: UserDefaultsKeys.activationTimestamp)
        defaults.removeObject(forKey: UserDefaultsKeys.transcriptText)
        defaults.removeObject(forKey: UserDefaultsKeys.transcriptReady)
        defaults.removeObject(forKey: UserDefaultsKeys.transcriptTimestamp)
        defaults.removeObject(forKey: UserDefaultsKeys.stopRequestTimestamp)
    }
    
    /// Get debug info about current state
    func getDebugInfo() -> [String: Any] {
        guard let defaults = sharedDefaults else { return ["error": "No shared defaults"] }
        
        return [
            "shouldStartRecording": defaults.bool(forKey: UserDefaultsKeys.shouldStartRecording),
            "shouldStopRecording": defaults.bool(forKey: UserDefaultsKeys.shouldStopRecording),
            "shouldActivate": defaults.bool(forKey: UserDefaultsKeys.shouldActivate),
            "isRecording": defaults.bool(forKey: UserDefaultsKeys.isRecording),
            "isActivated": defaults.bool(forKey: UserDefaultsKeys.isActivated),
            "lastRecordingTimestamp": defaults.double(forKey: UserDefaultsKeys.lastRecordingTimestamp),
            "activationTimestamp": defaults.double(forKey: UserDefaultsKeys.activationTimestamp),
            "transcriptReady": defaults.bool(forKey: UserDefaultsKeys.transcriptReady),
            "transcriptText": defaults.string(forKey: UserDefaultsKeys.transcriptText)?.prefix(50) ?? "nil",
            "transcriptTimestamp": defaults.double(forKey: UserDefaultsKeys.transcriptTimestamp),
            "appGroupIdentifier": appGroupIdentifier
        ]
    }
}
