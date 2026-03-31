//
//  AudioRecorder.swift
//  VoiceInk-ios
//

import Foundation
import Combine
import AVFoundation
import UIKit

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording: Bool = false
    @Published var currentRecordingURL: URL?
    @Published var currentDuration: TimeInterval = 0
    
    // Optimized circular buffer for audio levels (pre-allocated, no memory allocations during recording)
    private static let maxLevelsHistory = 40
    private var levelsHistoryBuffer: [CGFloat] = Array(repeating: 0, count: maxLevelsHistory)
    private var levelsHistoryIndex: Int = 0
    private var levelsHistoryCount: Int = 0
    
    @Published var levelsHistory: [CGFloat] = [] // Computed property for UI consumption
    
    private var audioRecorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private let sessionManager = AudioSessionManager.shared

    func startRecording() async throws {
        Logger.debug("startRecording() called", category: "AudioRecorder")
        
        // Clean up any existing recorder first
        // This is critical - if a previous recorder wasn't fully cleaned up, it can block new recordings
        if let existingRecorder = audioRecorder {
            Logger.debug("Cleaning up existing recorder before starting new one", category: "AudioRecorder")
            existingRecorder.stop()
            audioRecorder = nil
            // Small delay to ensure cleanup is complete (non-blocking)
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
        
        // Check if we're in keyboard mode and cache the value to prevent race conditions
        let coordinator = AppGroupCoordinator.shared
        let isKeyboardMode = coordinator.isActivated
        Logger.debug("Keyboard mode: \(isKeyboardMode)", category: "AudioRecorder")
        
        // Consolidate session activation logic into a single check
        // Ensure session is active before proceeding (idempotent operation)
        if !sessionManager.isSessionActive {
            let appState = UIApplication.shared.applicationState
            Logger.debug("Session not active, app state: \(appState.rawValue)", category: "AudioRecorder")
            guard appState == .active else {
                Logger.error("Session not active but app is in background - cannot activate", category: "AudioRecorder")
                throw NSError(domain: "com.asterayx.VoiceInk.AudioRecorder", code: 1005, userInfo: [NSLocalizedDescriptionKey: "Cannot activate audio session in background. Session must be activated while app is in foreground."])
            }
            Logger.debug("Activating session (app is active)", category: "AudioRecorder")
            try await sessionManager.activateSessionForRecording()
            Logger.info("Session activated successfully", category: "AudioRecorder")
        } else if isKeyboardMode {
            Logger.debug("Keyboard mode - session is active", category: "AudioRecorder")
        }
        
        let filename = "recording_\(Int(Date().timeIntervalSince1970)).wav"
        let url = Self.recordingsDirectory().appendingPathComponent(filename)
        Logger.debug("Recording file path: \(url.path)", category: "AudioRecorder")

        // Whisper-compatible format: 16kHz mono WAV
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        Logger.debug("Creating AVAudioRecorder instance", category: "AudioRecorder")
        // CRITICAL: Ensure any previous failed recorder is cleared before creating new one
        // This prevents "invalid reuse after initialization failure" errors
        audioRecorder = nil
        
        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true
        } catch {
            // If creation fails, ensure recorder is nil
            audioRecorder = nil
            Logger.error("Failed to create AVAudioRecorder: \(error.localizedDescription)", category: "AudioRecorder")
            throw NSError(domain: "com.asterayx.VoiceInk.AudioRecorder", code: 1003, userInfo: [NSLocalizedDescriptionKey: "Failed to create AVAudioRecorder: \(error.localizedDescription)"])
        }
        
        // Verify session is actually active before attempting to record
        guard let recorder = audioRecorder else {
            Logger.error("AVAudioRecorder instance is nil after creation", category: "AudioRecorder")
            throw NSError(domain: "com.asterayx.VoiceInk.AudioRecorder", code: 1003, userInfo: [NSLocalizedDescriptionKey: "AVAudioRecorder instance is nil"])
        }
        
        // Verify session is still active (it was activated above, but double-check)
        // This is idempotent - if already active, no-op
        if !sessionManager.isSessionActive {
            Logger.warning("Session became inactive after recorder creation, reactivating", category: "AudioRecorder")
            try await sessionManager.activateSessionForRecording()
        }
        
        // Prepare the recorder
        Logger.debug("Preparing recorder", category: "AudioRecorder")
        guard recorder.prepareToRecord() else {
            Logger.error("Failed to prepare recorder", category: "AudioRecorder")
            // CRITICAL: Clear the failed recorder to prevent "invalid reuse after initialization failure"
            audioRecorder = nil
            throw NSError(domain: "com.asterayx.VoiceInk.AudioRecorder", code: 1004, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare recorder for recording"])
        }
        
        // Small delay after preparation to ensure recorder is ready (non-blocking)
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        // Verify session is still active before starting
        if !sessionManager.isSessionActive {
            Logger.warning("Session became inactive after preparation, reactivating", category: "AudioRecorder")
            try await sessionManager.activateSessionForRecording()
        }
        
        // CRITICAL: Check app state before calling record()
        // Even with active session, record() will fail if app is in background
        let appState = UIApplication.shared.applicationState
        guard appState == .active else {
            Logger.error("App is not in foreground (state: \(appState.rawValue))", category: "AudioRecorder")
            throw NSError(domain: "com.asterayx.VoiceInk.AudioRecorder", code: 1006, userInfo: [NSLocalizedDescriptionKey: "Cannot start recording in background. App must be in foreground to start recording. Session is active but record() requires foreground state."])
        }
        
        // Start recording - simplified retry logic (KISS principle)
        Logger.debug("Calling record()", category: "AudioRecorder")
        var recordStarted = recorder.record()
        
        // Simple retry if first attempt fails (only if app is active)
        if !recordStarted && appState == .active {
            Logger.warning("First record() attempt failed, retrying", category: "AudioRecorder")
            // Clean up and retry once
            recorder.stop()
            // CRITICAL: Clear the failed recorder before creating a new one
            audioRecorder = nil
            try? AVAudioSession.sharedInstance().setActive(false)
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
            try await sessionManager.activateSessionForRecording()
            try? await Task.sleep(nanoseconds: 150_000_000) // 0.15 seconds
            
            // Recreate recorder
            do {
                let newRecorder = try AVAudioRecorder(url: url, settings: settings)
                newRecorder.delegate = self
                newRecorder.isMeteringEnabled = true
                
                // Prepare the new recorder
                guard newRecorder.prepareToRecord() else {
                    Logger.error("Failed to prepare new recorder in retry", category: "AudioRecorder")
                    // Clear failed recorder to prevent reuse
                    audioRecorder = nil
                    throw NSError(domain: "com.asterayx.VoiceInk.AudioRecorder", code: 1004, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare recorder for recording (retry)"])
                }
                
                audioRecorder = newRecorder
                try? await Task.sleep(nanoseconds: 150_000_000) // 0.15 seconds
                recordStarted = newRecorder.record()
            } catch {
                // If recorder creation or preparation fails, ensure it's cleared
                audioRecorder = nil
                throw error
            }
        }
        
        guard recordStarted else {
            let sessionActive = sessionManager.isSessionActive
            let category = AVAudioSession.sharedInstance().category.rawValue
            let errorMessage = "Failed to start AVAudioRecorder. Session active: \(sessionActive), Category: \(category). This may happen if there is a conflict with another app using the microphone."
            Logger.error("Failed to start - record() returned false. Debug: isSessionActive=\(sessionActive), category=\(category)", category: "AudioRecorder")
            // CRITICAL: Clear the failed recorder to prevent "invalid reuse after initialization failure"
            audioRecorder?.stop()
            audioRecorder = nil
            throw NSError(domain: "com.asterayx.VoiceInk.AudioRecorder", code: 1001, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }

        Logger.info("Recording started successfully", category: "AudioRecorder")
        // Batch related state updates to reduce view re-renders
        // Note: Views observing this object can handle animations if needed
        currentRecordingURL = url
        isRecording = true
        currentDuration = 0

        // Optimized timer: use RunLoop.main for proper scheduling and ensure cleanup
        meterTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.audioRecorder?.updateMeters()
                // Note: Duration is managed by RecordingManager to avoid duplication

                if let power = self.audioRecorder?.averagePower(forChannel: 0) {
                    // Convert dB (-160..0) to 0..1
                    let normalized = max(0, min(1, (power + 60) / 60))
                    
                    // Use circular buffer for efficient storage (no allocations)
                    self.levelsHistoryBuffer[self.levelsHistoryIndex] = CGFloat(normalized)
                    self.levelsHistoryIndex = (self.levelsHistoryIndex + 1) % Self.maxLevelsHistory
                    if self.levelsHistoryCount < Self.maxLevelsHistory {
                        self.levelsHistoryCount += 1
                    }
                    
                    // Update published property for UI (update every 5 samples to reduce UI updates)
                    // This balances smooth visualization with performance
                    // Update for first 5 samples, then every 5th sample after that
                    if self.levelsHistoryCount <= 5 || self.levelsHistoryCount % 5 == 0 {
                        self.updateLevelsHistoryForUI()
                    }
                }
            }
        }
        RunLoop.main.add(meterTimer!, forMode: .common)
    }

    func stopRecording() {
        Logger.debug("Stopping recording", category: "AudioRecorder")
        
        // Stop the recorder
        audioRecorder?.stop()
        
        // Clean up timer
        meterTimer?.invalidate()
        meterTimer = nil
        
        // Clear recorder reference
        audioRecorder = nil
        // State update - views can handle animations if needed
        isRecording = false
        
        // Reset circular buffer
        levelsHistoryIndex = 0
        levelsHistoryCount = 0
        levelsHistory = []
        
        // Check if we're in keyboard mode (activated session)
        let coordinator = AppGroupCoordinator.shared
        if coordinator.isActivated && sessionManager.isSessionActive {
            // In keyboard mode, keep session active for 10 minutes
            let originalTimeout = AppSettings.shared.audioSessionTimeoutSeconds
            AppSettings.shared.audioSessionTimeoutSeconds = 600
            sessionManager.scheduleDeactivation()
            AppSettings.shared.audioSessionTimeoutSeconds = originalTimeout
            Logger.debug("Extended session timeout after stopping recording (keyboard mode)", category: "AudioRecorder")
        } else if !coordinator.isActivated {
            // Normal mode: schedule deactivation with configured timeout
            sessionManager.scheduleDeactivation()
        } else {
            // Session not active in keyboard mode - try to reactivate if app is in foreground
            if UIApplication.shared.applicationState == .active {
                Task {
                    do {
                        try await sessionManager.activateSessionForRecording()
                        Logger.info("Session reactivated (app was in foreground)", category: "AudioRecorder")
                    } catch {
                        Logger.error("Failed to reactivate session: \(error.localizedDescription)", category: "AudioRecorder")
                    }
                }
            }
        }
    }

    func discard() {
        audioRecorder?.stop()
        audioRecorder = nil
        meterTimer?.invalidate()
        meterTimer = nil
        // State update - views can handle animations if needed
        isRecording = false
        
        // Reset circular buffer
        levelsHistoryIndex = 0
        levelsHistoryCount = 0
        levelsHistory = []
        
        if let url = currentRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        currentRecordingURL = nil
        currentDuration = 0
        
        // Check if we're in keyboard mode (activated session)
        let coordinator = AppGroupCoordinator.shared
        if coordinator.isActivated {
            sessionManager.extendTimeout()
            Logger.debug("Extended session timeout after discarding recording (keyboard mode)", category: "AudioRecorder")
        } else {
            sessionManager.scheduleDeactivation()
        }
    }

    static func recordingsDirectory() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    
    // MARK: - Circular Buffer Helpers
    
    /// Updates the published levelsHistory array from the circular buffer
    /// This is called periodically to update the UI without excessive allocations
    private func updateLevelsHistoryForUI() {
        guard levelsHistoryCount > 0 else {
            levelsHistory = []
            return
        }
        
        // Build array from circular buffer in correct chronological order
        // When buffer is not full, start from index 0
        // When buffer is full, start from levelsHistoryIndex (oldest entry) and wrap around
        var result: [CGFloat] = []
        result.reserveCapacity(levelsHistoryCount)
        
        if levelsHistoryCount < Self.maxLevelsHistory {
            // Buffer not full yet - data is sequential from index 0
            for i in 0..<levelsHistoryCount {
                result.append(levelsHistoryBuffer[i])
            }
        } else {
            // Buffer is full - start from levelsHistoryIndex (oldest) and wrap around
            for i in 0..<Self.maxLevelsHistory {
                let index = (levelsHistoryIndex + i) % Self.maxLevelsHistory
                result.append(levelsHistoryBuffer[index])
            }
        }
        
        levelsHistory = result
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {}


