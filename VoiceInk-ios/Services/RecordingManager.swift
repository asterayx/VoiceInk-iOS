import SwiftUI
import SwiftData
import AVFoundation
import Combine
import UIKit
import Foundation

extension Notification.Name {
    static let stopRecordingFromKeyboard = Notification.Name("stopRecordingFromKeyboard")
    static let recordingStarted = Notification.Name("recordingStarted")
    static let translationCompleted = Notification.Name("translationCompleted")
}

enum RecordingState: Equatable {
    case idle
    case recording
    case processing
    case completed(String)
    case error(String)
}

private enum MicrophonePermissionStatus {
    case granted, denied, undetermined
}

enum ActiveRecordingAlert: Identifiable {
    case permissionDenied
    case busy
    case generic(Error)
    
    var id: String {
        switch self {
        case .permissionDenied: return "permissionDenied"
        case .busy: return "busy"
        case .generic(let error): return "generic-\(error.localizedDescription)"
        }
    }
}
 
@MainActor
final class RecordingManager: ObservableObject {
    @Published var recordingState: RecordingState = .idle
    @Published var animate = false
    @Published var isRecordingSheetPresented = false
    @Published var activeRecordingAlert: ActiveRecordingAlert?
    @Published var currentRecordingNote: Transcription?
    @Published var currentDuration: Double = 0
    @Published var processingNote: Transcription? // Temporary note being processed (not in SwiftData yet)
    
    private let recorder = AudioRecorder()
    private let orchestrator = TranscriptionOrchestrator()
    private let settings = AppSettings.shared
    private var durationTimer: Timer?
    
    // Serial queue for atomic state transitions to prevent race conditions
    private let stateQueue = DispatchQueue(label: "com.asterayx.VoiceInk.RecordingManager.state", qos: .userInitiated)
    private var _isStartingRecording = false // Internal flag to prevent concurrent starts

    private let sessionManager = AudioSessionManager.shared
    private let coordinator = AppGroupCoordinator.shared
    // Thread-safe flag to track if recording was stopped from keyboard
    private var wasStoppedFromKeyboard = false {
        didSet {
            // Ensure coordinator state stays in sync
            if !wasStoppedFromKeyboard && oldValue {
                // Flag was reset, ensure coordinator state is updated if needed
                coordinator.updateRecordingState(isRecording)
            }
        }
    }
    
    
    var isRecording: Bool {
        recordingState == .recording
    }
    
    // MARK: - Initialization
    init() {
        Logger.debug("RecordingManager initialized", category: "RecordingManager")
        setupCoordinatorCallbacks()
        setupPermissionObserver()
    }
    
    deinit {
        durationTimer?.invalidate()
    }
    
    // MARK: - Coordinator Setup
    private func setupCoordinatorCallbacks() {
        // Simplified: Since app is always in foreground when opened via URL scheme,
        // we can directly start recording without complex state checking
        coordinator.onStartRecordingRequested = { [weak self] in
            guard let self = self else { return }
            Logger.debug("Start recording requested (app is in foreground)", category: "RecordingManager")
            
            // Only start if not already recording
            guard !self.isRecording else {
                Logger.warning("Already recording, ignoring duplicate request", category: "RecordingManager")
                return
            }
            
            // Start recording flow directly
            self.startRecordingFlow()
        }
        
        coordinator.onStopRecordingRequested = { [weak self] in
            guard let self = self else {
                Logger.warning("Stop callback: self is nil", category: "RecordingManager")
                return
            }
            Logger.debug("Stop recording requested from keyboard extension (via callback)", category: "RecordingManager")
            // Defer coordinator property access to avoid early UserDefaults access
            let isActivated = self.coordinator.isActivated
            Logger.debug("Current state - isRecording: \(self.isRecording), isActivated: \(isActivated)", category: "RecordingManager")
            guard self.isRecording else {
                Logger.warning("Stop requested but not currently recording - ignoring", category: "RecordingManager")
                return
            }
            // Atomically mark that this was stopped from keyboard
            self.stateQueue.sync {
                self.wasStoppedFromKeyboard = true
            }
            Logger.debug("Marked as stopped from keyboard, posting notification", category: "RecordingManager")
            // We need modelContext, so we'll handle this via a notification instead
            // Post on main thread to ensure it's processed
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .stopRecordingFromKeyboard, object: nil)
            }
        }
        
        coordinator.onActivationRequested = { [weak self] in
            guard let self = self else { return }
            Logger.debug("Activation requested (app is in foreground)", category: "RecordingManager")
            self.handleActivationRequest()
        }
        
        Logger.debug("Coordinator callbacks set up", category: "RecordingManager")
    }
    
    // MARK: - Activation Flow
    
    private func handleActivationRequest() {
        Logger.debug("handleActivationRequest() called", category: "RecordingManager")
        
        // Check permissions first
        let permissionStatus = checkPermissionStatus()
        Logger.debug("Permission status: \(permissionStatus)", category: "RecordingManager")
        
        switch permissionStatus {
        case .granted:
            // Permissions already granted, just activate session
            Logger.debug("Permissions already granted, activating session", category: "RecordingManager")
            activateSessionForKeyboard()
        case .denied:
            // Permissions denied
            Logger.warning("Permissions denied, showing alert", category: "RecordingManager")
            activeRecordingAlert = .permissionDenied
            coordinator.updateActivationState(false)
        case .undetermined:
            // Request permissions (app is in foreground when opened via URL)
            Logger.debug("Permissions undetermined, requesting permission", category: "RecordingManager")
            requestPermission { [weak self] granted in
                Logger.debug("Permission request completed, granted: \(granted)", category: "RecordingManager")
                if granted {
                    Logger.debug("Permission granted, activating session", category: "RecordingManager")
                    self?.activateSessionForKeyboard()
                } else {
                    Logger.warning("Permission denied by user", category: "RecordingManager")
                    self?.activeRecordingAlert = .permissionDenied
                    self?.coordinator.updateActivationState(false)
                }
            }
        }
    }
    
    private func activateSessionForKeyboard() {
        Logger.debug("activateSessionForKeyboard() called", category: "RecordingManager")
        
        Task {
            do {
                // Activate audio session with 10-minute timeout for keyboard mode
                Logger.debug("Activating audio session", category: "RecordingManager")
                try await sessionManager.activateSessionForRecording()
                Logger.info("Audio session activated successfully", category: "RecordingManager")
                
                // Set timeout to 10 minutes (600 seconds) for keyboard mode
                // Temporarily override the setting
                let originalTimeout = settings.audioSessionTimeoutSeconds
                settings.audioSessionTimeoutSeconds = 600
                
                // Schedule deactivation after 10 minutes
                sessionManager.scheduleDeactivation()
                
                // Restore original timeout setting
                settings.audioSessionTimeoutSeconds = originalTimeout
                
                // Update coordinator state
                coordinator.updateActivationState(true)
                
                // Show persistent notification to keep app active in background
                NotificationManager.shared.showActiveSessionNotification()
                
                Logger.info("Audio session activated for keyboard mode (10-minute window)", category: "RecordingManager")
            } catch {
                Logger.error("Failed to activate session for keyboard: \(error.localizedDescription)", category: "RecordingManager")
                coordinator.updateActivationState(false)
                activeRecordingAlert = .generic(error)
            }
        }
    }
    
    // MARK: - Recording Flow (Simplified)
    

    
    // MARK: - Recording Flow
    func startRecordingFlow() {
        Logger.debug("startRecordingFlow() called", category: "RecordingManager")
        
        // Atomic check and set to prevent race conditions
        var shouldProceed = false
        stateQueue.sync {
            guard !isRecording && !_isStartingRecording else {
                Logger.warning("Already recording or starting, ignoring duplicate startRecordingFlow() call", category: "RecordingManager")
                return
            }
            _isStartingRecording = true
            shouldProceed = true
        }
        
        guard shouldProceed else { return }
        
        // Check app state - must be in foreground
        let appState = UIApplication.shared.applicationState
        guard appState == .active else {
            stateQueue.sync { _isStartingRecording = false }
            Logger.error("App is not in foreground (state: \(appState.rawValue)), cannot start recording", category: "RecordingManager")
            activeRecordingAlert = .generic(NSError(domain: "com.asterayx.VoiceInk.RecordingManager", code: 1007, userInfo: [NSLocalizedDescriptionKey: "App must be in foreground to start recording"]))
            return
        }
        
        let permissionStatus = checkPermissionStatus()
        Logger.debug("Permission status: \(permissionStatus), Audio session active: \(sessionManager.isSessionActive), Coordinator isActivated: \(coordinator.isActivated)", category: "RecordingManager")
        
        switch permissionStatus {
        case .granted:
            Logger.debug("Permissions granted, updating UI immediately", category: "RecordingManager")
            // Update UI state immediately for instant feedback
            stateQueue.sync {
                _isStartingRecording = false
            }
            recordingState = .recording
            animate = true
            coordinator.updateRecordingState(true)
            // Continue with async setup in background
            Task { await proceedToStartRecording() }
        case .denied:
            stateQueue.sync { _isStartingRecording = false }
            Logger.warning("Permissions denied, showing alert", category: "RecordingManager")
            activeRecordingAlert = .permissionDenied
        case .undetermined:
            Logger.debug("Permissions undetermined, requesting permission", category: "RecordingManager")
            requestPermission { [weak self] granted in
                Logger.debug("Permission request completed, granted: \(granted)", category: "RecordingManager")
                if granted {
                    // Update UI state immediately
                    self?.stateQueue.sync { self?._isStartingRecording = false }
                    self?.recordingState = .recording
                    self?.animate = true
                    self?.coordinator.updateRecordingState(true)
                    // Continue with async setup in background
                    Task { @MainActor in
                        await self?.proceedToStartRecording()
                    }
                } else {
                    self?.stateQueue.sync { self?._isStartingRecording = false }
                    Logger.warning("Permission denied by user", category: "RecordingManager")
                    self?.activeRecordingAlert = .permissionDenied
                }
            }
        }
    }
    
    private func proceedToStartRecording() async {
        Logger.debug("proceedToStartRecording() called", category: "RecordingManager")
        
        // Verify app is still in foreground
        let appState = UIApplication.shared.applicationState
        guard appState == .active else {
            Logger.error("App is not in foreground (state: \(appState.rawValue)), cannot proceed", category: "RecordingManager")
            activeRecordingAlert = .generic(NSError(domain: "com.asterayx.VoiceInk.RecordingManager", code: 1008, userInfo: [NSLocalizedDescriptionKey: "App must be in foreground to start recording"]))
            recordingState = .idle
            coordinator.updateRecordingState(false)
            return
        }
        
        // Verify audio session is active before starting
        if !sessionManager.isSessionActive {
            Logger.warning("Audio session is not active, attempting to activate", category: "RecordingManager")
            do {
                try await sessionManager.activateSessionForRecording()
                Logger.info("Audio session activated successfully", category: "RecordingManager")
            } catch {
                Logger.error("Failed to activate audio session: \(error.localizedDescription)", category: "RecordingManager")
                activeRecordingAlert = .generic(error)
                recordingState = .idle
                coordinator.updateRecordingState(false)
                return
            }
        }
        
        // Cache keyboard mode state to prevent race conditions from state changes
        let isKeyboardMode = coordinator.isActivated
        
        // If session is already activated (keyboard mode), extend the timeout
        if isKeyboardMode {
            Logger.debug("Keyboard mode detected, extending audio session timeout", category: "RecordingManager")
            sessionManager.extendTimeout()
        }
        
        // Auto-select first mode if none is selected
        if settings.selectedModeId == nil && !settings.modes.isEmpty {
            settings.selectedModeId = settings.modes.first?.id
            Logger.debug("Auto-selected first mode: \(settings.modes.first?.name ?? "unknown")", category: "RecordingManager")
        }
        
        Logger.debug("Starting audio recorder", category: "RecordingManager")
        
        Task { @MainActor in
            do {
                try await recorder.startRecording()
                Logger.info("Audio recorder started successfully", category: "RecordingManager")
                
                startDurationTimer()
                
                // Verify recording actually started
                guard recorder.isRecording else {
                    throw NSError(domain: "com.asterayx.VoiceInk.RecordingManager", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Recording failed to start - AVAudioRecorder.record() returned false"])
                }
                
                // Post notification that recording has started
                NotificationCenter.default.post(name: .recordingStarted, object: nil)
            } catch {
                Logger.error("Recording failed to start: \(error.localizedDescription)", category: "RecordingManager")
                
                // Ensure starting flag is cleared on error
                stateQueue.sync { _isStartingRecording = false }
                
                // Batch related state updates
                withAnimation {
                    activeRecordingAlert = .generic(error)
                    recordingState = .idle
                    animate = false
                }
                coordinator.updateRecordingState(false)
            }
        }
    }
    
    func stopRecording(modelContext: ModelContext, fromKeyboard: Bool = false) {
        Logger.debug("stopRecording() called, fromKeyboard: \(fromKeyboard)", category: "RecordingManager")
        
        // Atomically set flag and check state to prevent race conditions
        let shouldStoreTranscript = stateQueue.sync { () -> Bool in
            // Set flag if stopped from keyboard
            if fromKeyboard {
                wasStoppedFromKeyboard = true
            }
            // Capture flag value before any potential reset
            return wasStoppedFromKeyboard
        }
        
        // Stop recording and get file info
        recorder.stopRecording()
        stopDurationTimer()
        
        guard let fileURL = recorder.currentRecordingURL else {
            Logger.warning("No recording file URL available", category: "RecordingManager")
            // Reset flag if we couldn't stop properly
            stateQueue.sync { wasStoppedFromKeyboard = false }
            return
        }
        
        // Store relative path and duration
        let audioFileName = fileURL.lastPathComponent
        let recordingDuration = currentDuration
        
        // If stopped from keyboard, clear any old transcript first
        if shouldStoreTranscript {
            coordinator.clearOldTranscript()
        }
        
        // Create note in memory (NOT inserted into SwiftData yet)
        // Will only be inserted when translation completes
        let note = Transcription(
            text: "",
            duration: recordingDuration,
            audioFileURL: audioFileName,
            transcriptionStatus: .pending
        )
        
        // Atomically update all related state to keep everything in sync
        stateQueue.sync {
            // Reset the flag after checking
            wasStoppedFromKeyboard = false
        }
        
        // Set processing state and store note temporarily
        withAnimation {
            recordingState = .processing
            animate = false
            processingNote = note
            currentRecordingNote = nil
            isRecordingSheetPresented = false
        }
        
        // Update coordinator state (must be after local state update)
        coordinator.updateRecordingState(false)
        
        // Note: We don't deactivate the session here if it's in keyboard mode
        // The session will stay active for the 10-minute window
        // The timeout will be extended on the next recording start
        
        // Start background transcription and translation
        // Note will only be inserted when translation completes
        transcribeInBackground(note: note, audioFileName: audioFileName, recordingDuration: recordingDuration, modelContext: modelContext, shouldStoreTranscript: shouldStoreTranscript)
    }
    
    func cancelRecording() {
        recorder.discard()
        stopDurationTimer()
        
        // Atomically reset flag and update state
        stateQueue.sync {
            wasStoppedFromKeyboard = false
        }
        
        // Batch related state updates to reduce view re-renders
        withAnimation {
            recordingState = .idle
            animate = false
            isRecordingSheetPresented = false
        }
        currentDuration = 0
        
        // Update coordinator state (must be after local state update)
        coordinator.updateRecordingState(false)
    }
    
    // MARK: - Permissions
    private func checkPermissionStatus() -> MicrophonePermissionStatus {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }
    
    /// Setup observer for microphone permission changes
    /// This handles the case where permission is revoked while the app is running
    private func setupPermissionObserver() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            
            // Check if permission was revoked
            let currentStatus = self.checkPermissionStatus()
            if currentStatus == .denied && self.isRecording {
                Logger.warning("Microphone permission revoked while recording", category: "RecordingManager")
                // Stop recording if permission was revoked
                // Note: This requires modelContext, so we'll handle via notification
                NotificationCenter.default.post(name: .stopRecordingFromKeyboard, object: nil)
                self.activeRecordingAlert = .permissionDenied
            }
        }
    }
    
    private func requestPermission(completion: @escaping (Bool) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }
    
    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }
    
    // MARK: - Duration Timer
    private func startDurationTimer() {
        // Atomically stop any existing timer before starting a new one
        stateQueue.sync {
            durationTimer?.invalidate()
            durationTimer = nil
        }
        
        currentDuration = 0
        // Optimized timer: use RunLoop.main for proper scheduling and ensure cleanup
        let newTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.currentDuration += 0.1
            }
        }
        
        stateQueue.sync {
            durationTimer = newTimer
        }
        RunLoop.main.add(newTimer, forMode: .common)
    }
    
    private func stopDurationTimer() {
        stateQueue.sync {
            durationTimer?.invalidate()
            durationTimer = nil
        }
    }
    
    // MARK: - Transcription
    private func transcribeInBackground(note: Transcription, audioFileName: String, recordingDuration: Double, modelContext: ModelContext, shouldStoreTranscript: Bool = false) {
        Logger.debug("transcribeInBackground() called - audioFileName: \(audioFileName), duration: \(recordingDuration)s, shouldStoreTranscript: \(shouldStoreTranscript)", category: "RecordingManager")
        
        Task {
            defer {
                // Clean up recorder state
                recorder.currentRecordingURL = nil
                recorder.currentDuration = 0
            }
            
            await orchestrator.processRecording(
                note: note,
                audioFileName: audioFileName,
                recordingDuration: recordingDuration,
                modelContext: modelContext,
                shouldStoreTranscript: shouldStoreTranscript,
                onComplete: { [weak self] in
                    guard let self = self else { return }
                    // Clear processing state and reset to idle BEFORE cleanup
                    // This allows UI to update immediately
                    self.processingNote = nil
                    self.recordingState = .idle
                    
                    // Defer cleanup to avoid blocking UI update
                    // This prevents the cleanup save from interfering with the insert
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
                        self.cleanupOldRecordings(modelContext: modelContext)
                    }
                },
                onError: { [weak self] errorMessage in
                    guard let self = self else { return }
                    // Clear processing state immediately
                    self.processingNote = nil
                    self.recordingState = .idle
                    
                    // Defer cleanup
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
                        self.cleanupOldRecordings(modelContext: modelContext)
                    }
                }
            )
        }
    }
    
    // MARK: - Cleanup
    
    /// Keep only the last 10 recordings and delete older ones
    /// OPTIMIZATION: This is called with a delay to avoid interfering with UI updates
    private func cleanupOldRecordings(modelContext: ModelContext) {
        Task { @MainActor in
            do {
                // Fetch all transcriptions sorted by timestamp (newest first)
                let descriptor = FetchDescriptor<Transcription>(
                    sortBy: [SortDescriptor(\Transcription.timestamp, order: .reverse)]
                )
                let allNotes = try modelContext.fetch(descriptor)
                
                // If we have more than 10, delete the oldest ones
                if allNotes.count > 10 {
                    let notesToDelete = Array(allNotes.suffix(from: 10))
                    Logger.info("Cleaning up \(notesToDelete.count) old recordings (keeping last 10)", category: "RecordingManager")
                    
                    // Collect audio paths to delete before deleting notes
                    var audioPathsToDelete: [String] = []
                    for note in notesToDelete {
                        if let audioPath = note.fullAudioPath, FileManager.default.fileExists(atPath: audioPath) {
                            audioPathsToDelete.append(audioPath)
                        }
                    }
                    
                    // Delete notes in batch
                    for note in notesToDelete {
                        modelContext.delete(note)
                    }
                    
                    // OPTIMIZATION: Single save operation for all deletions
                    modelContext.processPendingChanges()
                    try modelContext.save()
                    
                    // Delete audio files after database is updated (non-blocking)
                    Task.detached(priority: .utility) {
                        for audioPath in audioPathsToDelete {
                            try? FileManager.default.removeItem(atPath: audioPath)
                            Logger.debug("Deleted audio file: \(audioPath)", category: "RecordingManager")
                        }
                    }
                    
                    Logger.info("Successfully cleaned up old recordings", category: "RecordingManager")
                }
            } catch {
                Logger.error("Failed to cleanup old recordings: \(error.localizedDescription)", category: "RecordingManager")
            }
        }
    }
    
}
