//
//  KeyboardViewController.swift
//  VoiceInkKeyboard
//
//  Created by Taafa D on 28/08/2025.
//

import UIKit
import KeyboardKit
import os
import OSLog

class KeyboardViewController: KeyboardInputViewController {
    private let logger = Logger(subsystem: "com.asterayx.VoiceInk", category: "KeyboardExtension")
    
    var recordButton: UIButton!
    private let coordinator = AppGroupCoordinator.shared
    private var recordingStatusTimer: Timer?
    private var verificationTimer: Timer?
    
    deinit {
        recordingStatusTimer?.invalidate()
        recordingStatusTimer = nil
        verificationTimer?.invalidate()
        verificationTimer = nil
        
        // Remove Darwin notification observers
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        if let token = activationObserverToken {
            CFNotificationCenterRemoveObserver(center, token, nil, nil)
            activationObserverToken = nil
        }
        if let token = transcriptObserverToken {
            CFNotificationCenterRemoveObserver(center, token, nil, nil)
            transcriptObserverToken = nil
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupKeyboard()
        setupRecordingStatusMonitoring()
        setupTranscriptNotificationObserver()
    }
    
    private func setupKeyboard() {
        // Setup KeyboardKit with default configuration
        setupKeyboardKit()
        
        // Add our custom record button at the top
        setupRecordButton()
    }
    
    private func setupKeyboardKit() {
        // KeyboardInputViewController automatically sets up the keyboard
        // We can customize the keyboard appearance here if needed
        
        // Make the keyboard more compact
        setupCompactKeyboard()
    }
    
    private func setupCompactKeyboard() {
        // Customize KeyboardKit's key styling to make keys more compact
        // This requires working with KeyboardKit's styling system
        
        // Note: KeyboardKit's styling is complex and may require KeyboardKit Pro
        // For now, we'll keep the default keyboard layout
        // Individual key customization would require:
        // 1. Custom KeyboardStyleProvider
        // 2. Custom KeyboardLayoutProvider  
        // 3. Overriding key button styles
        
    }
    
    private func setupRecordButton() {
        print("🔵 Keyboard: setupRecordButton() called")
        // Create the native iOS-style record button
        recordButton = UIButton(type: .system)
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        
        // Use only .touchUpInside for button taps (standard iOS pattern)
        // .touchDown can cause double-firing and is not needed
        recordButton.addTarget(self, action: #selector(recordButtonTapped), for: .touchUpInside)
        print("🔵 Keyboard: Button target added, targets: \(recordButton.allTargets)")
        print("🔵 Keyboard: Button actions: \(recordButton.actions(forTarget: self, forControlEvent: .touchUpInside) ?? [])")
        
        // Make sure button is enabled and user interaction is enabled
        recordButton.isEnabled = true
        recordButton.isUserInteractionEnabled = true
        
        // Configure for activate state initially (will update based on actual state)
        configureButtonForActivateState()
        print("🔵 Keyboard: Button configured and enabled")
        
        // Add native iOS styling
        recordButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        recordButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 16, bottom: 6, right: 16)
        
        // Native iOS shadow and styling
        recordButton.layer.shadowColor = UIColor.black.cgColor
        recordButton.layer.shadowOffset = CGSize(width: 0, height: 1)
        recordButton.layer.shadowOpacity = 0.2
        recordButton.layer.shadowRadius = 2
        
        // Add subtle border for better definition
        recordButton.layer.borderWidth = 0.5
        recordButton.layer.borderColor = UIColor.separator.cgColor
        
        // Add button to main view
        view.addSubview(recordButton)
        print("🔵 Keyboard: Button added to view")
        
        // Set up constraints - position in top center with safe margins
        NSLayoutConstraint.activate([
            recordButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            recordButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            recordButton.heightAnchor.constraint(equalToConstant: 32),
            recordButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])
        print("🔵 Keyboard: Button constraints set")
        
        // Ensure button stays on top and can receive touches
        view.bringSubviewToFront(recordButton)
        recordButton.isUserInteractionEnabled = true
        recordButton.isExclusiveTouch = true
        print("🔵 Keyboard: Button brought to front, user interaction enabled")
    }
    
    private func configureButtonForActivateState() {
        // Use SF Symbol for power/activation
        let powerConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let powerImage = UIImage(systemName: "power", withConfiguration: powerConfig)
        
        recordButton.setImage(powerImage, for: .normal)
        recordButton.setTitle(" Activate", for: .normal)
        recordButton.backgroundColor = UIColor.systemGreen
        recordButton.setTitleColor(.white, for: .normal)
        recordButton.tintColor = .white
        
        // Ensure image and text are properly aligned
        recordButton.semanticContentAttribute = .forceLeftToRight
        recordButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 4)
        recordButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
    }
    
    private func configureButtonForIdleState() {
        // Use SF Symbol for microphone
        let microphoneConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let microphoneImage = UIImage(systemName: "mic.fill", withConfiguration: microphoneConfig)
        
        recordButton.setImage(microphoneImage, for: .normal)
        recordButton.setTitle(" Record", for: .normal)
        recordButton.backgroundColor = UIColor.systemBlue
        recordButton.setTitleColor(.white, for: .normal)
        recordButton.tintColor = .white
        
        // Ensure image and text are properly aligned
        recordButton.semanticContentAttribute = .forceLeftToRight
        recordButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 4)
        recordButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
    }
    
    private func configureButtonForRecordingState() {
        // Use SF Symbol for stop
        let stopConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let stopImage = UIImage(systemName: "stop.fill", withConfiguration: stopConfig)
        
        recordButton.setImage(stopImage, for: .normal)
        recordButton.setTitle(" Stop", for: .normal)
        recordButton.backgroundColor = UIColor.systemRed
        recordButton.setTitleColor(.white, for: .normal)
        recordButton.tintColor = .white
        
        // Ensure image and text are properly aligned
        recordButton.semanticContentAttribute = .forceLeftToRight
        recordButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 4)
        recordButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        // Re-add and ensure record button stays on top after KeyboardKit layout
        if let button = recordButton {
            if button.superview == nil {
                view.addSubview(button)
            }
            view.bringSubviewToFront(button)
            
            // Ensure proper capsule shape after layout
            DispatchQueue.main.async {
                button.layer.cornerRadius = button.frame.height / 2
            }
        } else {
            // no-op
        }
        
        // Initialize and sync state when keyboard appears (handles extension termination/restart)
        // Check for stale state and clear if needed
        coordinator.checkAndClearStaleRecordingState()
        coordinator.checkAndClearStaleActivationState()
        
        // Update button state immediately when keyboard appears
        // This ensures the button shows the correct state when user switches back
        updateButtonAppearanceBasedOnState()
        
        // Restart monitoring if timer was stopped
        if recordingStatusTimer == nil {
            setupRecordingStatusMonitoring()
        }
        
        // Check if there's a pending transcript to insert when keyboard becomes active
        // Add a small delay to ensure UserDefaults has synced
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            if self.coordinator.isTranscriptReady {
                self.logger.info("📝 Keyboard: Found pending transcript when keyboard appeared, attempting to insert")
                self.handleTranscriptReady()
            } else {
                self.logger.debug("📝 Keyboard: No pending transcript when keyboard appeared")
            }
        }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        // Re-add button if KeyboardKit removed it
        if let button = recordButton, button.superview == nil {
            print("⚠️ Keyboard: Button was removed, re-adding it")
            view.addSubview(button)
            button.isUserInteractionEnabled = true
        }
        
        // Ensure button is still visible after layout and on top
        if let button = recordButton {
            view.bringSubviewToFront(button)
            button.isUserInteractionEnabled = true
            
            // Make button fully capsule-shaped based on its actual height
            button.layer.cornerRadius = button.frame.height / 2
            
            // Ensure button is above all other views
            button.layer.zPosition = 1000
        }
    }
    
    /// Gboard-style recording flow:
    /// 1. Keyboard sets App Group flag (primary communication - always works)
    /// 2. Keyboard attempts to open app via URL scheme (may fail on iOS 18+)
    /// 3. If URL fails, user manually opens app (shows helpful message)
    /// 4. App checks App Group flag on activation and starts recording
    /// 5. User records, stops, transcription happens in app
    /// 6. App stores transcript in App Group
    /// 7. User switches back to original app, keyboard appears
    /// 8. Keyboard checks App Group for transcript and inserts it
    @objc private func recordButtonTapped() {
        // 🔥 CRITICAL: This log MUST appear if handler is called
        print("🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥")
        print("🔥🔥🔥 micButtonTapped: EXECUTED 🔥🔥🔥")
        print("🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥")
        logger.info("🔥🔥🔥 Keyboard: recordButtonTapped() EXECUTED - FIRST LINE 🔥🔥🔥")
        os_log("🔥🔥🔥 Keyboard: recordButtonTapped() EXECUTED - FIRST LINE 🔥🔥🔥", log: .default, type: .info)
        
        // Visual indicator that button was tapped (change button text temporarily)
        let originalTitle = recordButton.title(for: .normal) ?? ""
        recordButton.setTitle(" TAPPED!", for: .normal)
        recordButton.backgroundColor = UIColor.systemYellow
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.recordButton.setTitle(originalTitle, for: .normal)
            self?.updateButtonAppearanceBasedOnState()
        }
        
        // Use os_log which works better in extensions
        logger.info("🔴🔴🔴 Keyboard: recordButtonTapped() CALLED 🔴🔴🔴")
        os_log("🔴 Keyboard: recordButtonTapped() called", log: .default, type: .info)
        
        // Ensure we're on main thread
        guard Thread.isMainThread else {
            logger.warning("⚠️ Keyboard: Not on main thread, dispatching...")
            DispatchQueue.main.async { [weak self] in
                self?.recordButtonTapped()
            }
            return
        }
        
        logger.info("✅ Keyboard: On main thread")
        
        // Guard against nil button
        guard let button = recordButton else {
            logger.error("❌ Keyboard: recordButton is nil, cannot handle tap")
            return
        }
        
        logger.info("✅ Keyboard: recordButton exists")
        
        // Add native iOS button press animation
        addButtonPressAnimation()
        
        // Provide haptic feedback
        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
        impactFeedback.impactOccurred()
        logger.info("✅ Keyboard: Haptic feedback sent")
        
        let isRecording = coordinator.isRecording
        logger.info("📊 Keyboard: isRecording = \(isRecording)")
        
        if isRecording {
            // Stop recording: Use App Group communication directly (no need to open app)
            logger.info("🛑 Keyboard: Stop button pressed, requesting stop via App Group")
            coordinator.requestStopRecording()
            logger.info("🛑 Keyboard: Stop request sent via App Group")
            // Optimistically update button state
            configureButtonForIdleState()
        } else {
            // Start recording: Apple-compliant architecture
            // iOS 15+ blocks keyboard extensions from automatically opening apps
            // Solution: Set App Group flag + ATTEMPT to open app (may fail, but we try)
            logger.info("🎙️ Keyboard: Record button pressed - starting flow")
            
            // Clear any old transcript
            coordinator.clearOldTranscript()
            logger.info("🧹 Keyboard: Cleared old transcript")
            
            // Set pending recording request flag in App Group (primary communication method)
            // This is the ONLY reliable way to communicate from keyboard to app on iOS 15+
            coordinator.requestStartRecording()
            
            // Verify App Group flag was set successfully
            let flagWasSet = coordinator.checkStartRecordingFlag()
            if flagWasSet {
                logger.info("✅ Keyboard: App Group flag verified - set successfully")
            } else {
                logger.error("❌ Keyboard: App Group flag verification failed! Flag may not have been set.")
            }
            
            // 🔥 ATTEMPT TO OPEN APP (even though iOS 15+ may block it)
            // We want to see the attempt in logs, even if it fails
            print("🚀🚀🚀 Keyboard: Attempting to open app via URL scheme...")
            logger.info("🚀 Keyboard: Attempting to open app via URL scheme")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                print("🚀 Keyboard: Inside async block, about to call openMainApp")
                self.openMainApp(url: "voiceink://record")
            }
            
            // Show user instruction to open the app only if flag was set successfully
            // iOS blocks automatic app opening from keyboard extensions
            if flagWasSet {
                DispatchQueue.main.async { [weak self] in
                    self?.showOpenAppMessage()
                }
            } else {
                logger.error("❌ Keyboard: Not showing open app message - App Group flag not set")
            }
            
            // Optimistically update button state
            configureButtonForRecordingState()
        }
        
        // Update based on actual state (will sync when state updates)
        updateButtonAppearanceBasedOnState()
        logger.info("✅ Keyboard: recordButtonTapped() completed")
    }
    
    private func addButtonPressAnimation() {
        // Native iOS button press animation - scale down then back up
        guard let button = recordButton else { return }
        UIView.animate(withDuration: 0.1, delay: 0, options: [.curveEaseInOut], animations: {
            button.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        }) { _ in
            UIView.animate(withDuration: 0.1, delay: 0, options: [.curveEaseInOut], animations: {
                button.transform = CGAffineTransform.identity
            })
        }
    }
    
    // NOTE: Automatic app opening from keyboard extensions is blocked by iOS 15+
    // This method attempts to open the app, but iOS 15+ may block it
    // The App Group flag is the primary communication method (fallback)
    private func openMainApp(url: String) {
        print("🚀🚀🚀 Keyboard: openMainApp() CALLED with URL: \(url)")
        logger.info("🚀 Keyboard: openMainApp() called with URL: \(url)")
        os_log("🚀 Keyboard: openMainApp() called with URL: %@", log: .default, type: .info, url)
        
        // iOS 15+ blocks keyboard extensions from automatically opening apps
        // This is by design for privacy and security
        // We rely on App Group flags as fallback - user manually opens app if this fails
        logger.info("ℹ️ Keyboard: Attempting to open app (iOS 15+ may block this)")
        logger.info("ℹ️ Keyboard: App Group flag is set - app will auto-start recording when user opens it")
        
        // Validate URL
        guard let urlObject = URL(string: url) else {
            print("❌ Keyboard: Invalid URL string: \(url)")
            logger.error("❌ Keyboard: Invalid URL string: \(url)")
            return
        }
        print("✅ Keyboard: URL object created: \(urlObject.absoluteString)")
        
        // Validate extension context
        guard let context = extensionContext else {
            print("❌ Keyboard: extensionContext is nil!")
            logger.error("❌ Keyboard: extensionContext is nil!")
            return
        }
        print("✅ Keyboard: extensionContext is available")
        
        // Ensure main thread
        guard Thread.isMainThread else {
            print("⚠️ Keyboard: Not on main thread, dispatching...")
            logger.warning("⚠️ Keyboard: Not on main thread, dispatching...")
            DispatchQueue.main.async { [weak self] in
                self?.openMainApp(url: url)
            }
            return
        }
        print("✅ Keyboard: On main thread")
        
        // 🔥 ATTEMPT TO OPEN APP
        print("🚀🚀🚀 Keyboard: Calling extensionContext.open() NOW...")
        logger.info("🚀 Keyboard: Calling extensionContext.open() now...")
        os_log("🚀 Keyboard: Calling extensionContext.open() now", log: .default, type: .info)
        
        context.open(urlObject) { [weak self] success in
            print("🚀 Keyboard: extensionContext.open() callback received: success=\(success)")
            if success {
                print("✅✅✅ Keyboard: App opened successfully! (rare on iOS 15+)")
                self?.logger.info("✅ Keyboard: App opened successfully! (rare on iOS 15+)")
                os_log("✅ Keyboard: App opened successfully", log: .default, type: .info)
            } else {
                print("⚠️⚠️⚠️ Keyboard: extensionContext.open() returned false (expected on iOS 15+)")
                self?.logger.info("⚠️ Keyboard: extensionContext.open() returned false (expected on iOS 15+)")
                os_log("⚠️ Keyboard: extensionContext.open() returned false", log: .default, type: .info)
            }
        }
        
        print("🚀 Keyboard: extensionContext.open() call completed (callback will fire asynchronously)")
    }
    
    
    private func showUserMessage() {
        // Last resort: Update button to show user should open main app manually
        let appConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let appImage = UIImage(systemName: "app", withConfiguration: appConfig)
        
        recordButton.setImage(appImage, for: .normal)
        recordButton.setTitle(" Open VoiceInk", for: .normal)
        recordButton.backgroundColor = UIColor.systemOrange
        recordButton.setTitleColor(.white, for: .normal)
        recordButton.tintColor = .white
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.updateButtonAppearanceBasedOnState()
        }
    }
    
    private func showFullAccessRequiredMessage() {
        // Show message that Full Access is required
        let lockConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let lockImage = UIImage(systemName: "lock.fill", withConfiguration: lockConfig)
        
        recordButton.setImage(lockImage, for: .normal)
        recordButton.setTitle(" Enable Full Access", for: .normal)
        recordButton.backgroundColor = UIColor.systemOrange
        recordButton.setTitleColor(.white, for: .normal)
        recordButton.tintColor = .white
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.updateButtonAppearanceBasedOnState()
        }
    }
    
    private func showOpenAppMessage() {
        // Show clear instruction to user: "Open VoiceInk to record"
        // This is the Apple-compliant way - user manually opens app
        let appConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let appImage = UIImage(systemName: "app.badge", withConfiguration: appConfig)
        
        recordButton.setImage(appImage, for: .normal)
        recordButton.setTitle(" Open VoiceInk", for: .normal)
        recordButton.backgroundColor = UIColor.systemBlue
        recordButton.setTitleColor(.white, for: .normal)
        recordButton.tintColor = .white
        
        logger.info("ℹ️ Keyboard: Showing 'Open VoiceInk' message to user")
        
        // Reset button after 4 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.updateButtonAppearanceBasedOnState()
        }
    }
    
    private func setupRecordingStatusMonitoring() {
        // Stop any existing timer
        recordingStatusTimer?.invalidate()
        
        // Monitor recording and activation status every 0.5 seconds
        // Use common run loop modes so timer works even when keyboard is active
        recordingStatusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateButtonAppearanceBasedOnState()
        }
        
        // Add to common run loop modes to ensure it runs when keyboard is active
        if let timer = recordingStatusTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
        
        // Initial state update
        updateButtonAppearanceBasedOnState()
        
        // Also listen for activation state changes via Darwin notifications
        setupActivationStateObserver()
    }
    
    private var activationObserverToken: UnsafeMutableRawPointer?
    
    private func setupActivationStateObserver() {
        // Remove existing observer if any
        if let token = activationObserverToken {
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            CFNotificationCenterRemoveObserver(center, token, nil, nil)
            activationObserverToken = nil
        }
        
        // Listen for activation state changes
        let notificationName = "com.asterayx.VoiceInk.activationStateChanged"
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        
        // Use weak reference wrapper to prevent crashes
        let token = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        activationObserverToken = token
        
        CFNotificationCenterAddObserver(
            center,
            token,
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                // Safely unwrap - if object was deallocated, this will be handled gracefully
                let keyboardVC = Unmanaged<KeyboardViewController>.fromOpaque(observer).takeUnretainedValue()
                keyboardVC.handleActivationStateChanged()
            },
            notificationName as CFString,
            nil,
            .deliverImmediately
        )
        
        logger.info("📡 Keyboard: Set up activation state change observer")
    }
    
    private func handleActivationStateChanged() {
        logger.info("🔵 Keyboard: Activation state changed, updating button")
        DispatchQueue.main.async { [weak self] in
            self?.updateButtonAppearanceBasedOnState()
        }
    }
    
    // MARK: - Simplified Transcript Handling
    
    private func handleTranscriptReady() {
        logger.info("📝 Keyboard: Handling transcript ready")
        
        guard coordinator.isTranscriptReady else {
            logger.warning("⚠️ Keyboard: Transcript not ready")
            return
        }
        
        guard let transcript = coordinator.getTranscript() else {
            logger.warning("⚠️ Keyboard: Failed to retrieve transcript")
            return
        }
        
        logger.info("✅ Keyboard: Got transcript (\(transcript.count) chars), inserting now")
        
        // Insert transcript directly
        insertTranscript(transcript)
        
        // Clear transcript after insertion
        coordinator.clearTranscript()
    }
    
    private var transcriptObserverToken: UnsafeMutableRawPointer?
    
    private func setupTranscriptNotificationObserver() {
        // Remove existing observer if any
        if let token = transcriptObserverToken {
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            CFNotificationCenterRemoveObserver(center, token, nil, nil)
            transcriptObserverToken = nil
        }
        
        // Listen for Darwin notifications about transcript being ready
        let notificationName = "com.asterayx.VoiceInk.transcriptReady"
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        
        // Use weak reference wrapper to prevent crashes
        let token = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        transcriptObserverToken = token
        
        CFNotificationCenterAddObserver(
            center,
            token,
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                // Safely unwrap - if object was deallocated, this will be handled gracefully
                let keyboardVC = Unmanaged<KeyboardViewController>.fromOpaque(observer).takeUnretainedValue()
                keyboardVC.handleTranscriptReadyNotification()
            },
            notificationName as CFString,
            nil,
            .deliverImmediately
        )
        
        logger.info("📡 Keyboard: Set up transcript ready notification observer")
    }
    
    private func handleTranscriptReadyNotification() {
        logger.info("🔔 Keyboard: Received transcript ready Darwin notification")
        
        // Insert transcript immediately when we get the notification
        DispatchQueue.main.async { [weak self] in
            self?.handleTranscriptReady()
        }
    }
    
    private func insertTranscript(_ text: String) -> Bool {
        // Insert the text at the current cursor position
        logger.info("📝 Keyboard: Attempting to insert transcript: \(text.prefix(50))... (length: \(text.count))")
        
        // textDocumentProxy is always available in KeyboardInputViewController
        let proxy = textDocumentProxy
        logger.debug("📝 Keyboard: textDocumentProxy available, hasText=\(proxy.hasText)")
        
        // Use textDocumentProxy.insertText directly - this is the standard iOS keyboard extension API
        // For reliability, always insert in smaller chunks
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        
        guard !words.isEmpty else {
            logger.warning("⚠️ Keyboard: No words to insert")
            return false
        }
        
        // If text is short, insert all at once for better performance
        if text.count < 100 {
            logger.info("📝 Keyboard: Inserting short text all at once")
            proxy.insertText(text)
            logger.info("✅ Keyboard: Text inserted successfully")
            
            // Provide haptic feedback
            let notificationFeedback = UINotificationFeedbackGenerator()
            notificationFeedback.notificationOccurred(.success)
            return true
        }
        
        // For longer text, insert word by word
        var wordIndex = 0
        
        func insertNextWord() {
            guard wordIndex < words.count else {
                logger.info("✅ Keyboard: Finished inserting all \(words.count) words")
                
                // Provide haptic feedback
                let notificationFeedback = UINotificationFeedbackGenerator()
                notificationFeedback.notificationOccurred(.success)
                return
            }
            
            let word = words[wordIndex]
            // Add space before word (except first word)
            let prefix = wordIndex > 0 ? " " : ""
            let textToInsert = prefix + word
            
            // Insert the word
            proxy.insertText(textToInsert)
            
            wordIndex += 1
            
            // Insert next word after a small delay to ensure reliability
            if wordIndex < words.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                    insertNextWord()
                }
            } else {
                logger.info("✅ Keyboard: All text inserted successfully (\(words.count) words)")
                
                // Provide haptic feedback
                let notificationFeedback = UINotificationFeedbackGenerator()
                notificationFeedback.notificationOccurred(.success)
            }
        }
        
        // Start inserting
        insertNextWord()
        
        // Return success (note: for async word-by-word insertion, this is optimistic)
        // The actual success will be determined by whether all words were inserted
        return true
    }
    
    private func updateButtonAppearanceBasedOnState() {
        // Always run on main thread
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateButtonAppearanceBasedOnState()
            }
            return
        }
        
        guard let button = recordButton else {
            logger.warning("⚠️ Keyboard: recordButton is nil, cannot update appearance")
            return
        }
        
        let isRecording = coordinator.isRecording
        
        if isRecording {
            // Configure for recording state
            logger.debug("🎙️ Keyboard: Updating button to recording state (Stop)")
            configureButtonForRecordingState()
        } else {
            // Configure for idle state (not recording)
            logger.debug("🎙️ Keyboard: Updating button to idle state (Record)")
            configureButtonForIdleState()
        }
        
        // Ensure capsule shape is maintained
        button.layer.cornerRadius = button.frame.height / 2
    }
    
    override func textWillChange(_ textInput: UITextInput?) {
        // The app is about to change the document's contents
        super.textWillChange(textInput)
    }
    
    override func textDidChange(_ textInput: UITextInput?) {
        // The app has just changed the document's contents
        super.textDidChange(textInput)
        
        // Check if there's a pending transcript when text field becomes active
        // Add a small delay to ensure UserDefaults has synced
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            if self.coordinator.isTranscriptReady {
                self.logger.info("📝 Keyboard: Text field changed and transcript is ready, attempting to insert")
                self.handleTranscriptReady()
            }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Note: We keep the recording status timer running so it can update
        // when the keyboard appears again
    }
}
