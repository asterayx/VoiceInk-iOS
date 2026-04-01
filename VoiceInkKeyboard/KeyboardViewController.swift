//
//  KeyboardViewController.swift
//  VoiceInkKeyboard
//

import UIKit
import KeyboardKit
import os
import OSLog

class KeyboardViewController: KeyboardInputViewController {
    private let logger = Logger(subsystem: "com.asterayx.VoiceInk", category: "KeyboardExtension")

    // MARK: - UI Elements
    private var toolbarView: UIView!
    var recordButton: UIButton!
    private var modeButton: UIButton!

    private let coordinator = AppGroupCoordinator.shared
    private var recordingStatusTimer: Timer?
    private var activationObserverToken: UnsafeMutableRawPointer?
    private var transcriptObserverToken: UnsafeMutableRawPointer?

    // MARK: - Lifecycle

    deinit {
        recordingStatusTimer?.invalidate()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        if let t = activationObserverToken  { CFNotificationCenterRemoveObserver(center, t, nil, nil) }
        if let t = transcriptObserverToken  { CFNotificationCenterRemoveObserver(center, t, nil, nil) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupToolbar()
        setupRecordingStatusMonitoring()
        setupTranscriptNotificationObserver()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ensureToolbarOnTop()
        coordinator.checkAndClearStaleRecordingState()
        coordinator.checkAndClearStaleActivationState()
        updateButtonAppearanceBasedOnState()
        refreshModeButton()

        if recordingStatusTimer == nil { setupRecordingStatusMonitoring() }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            if self.coordinator.isTranscriptReady { self.handleTranscriptReady() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        ensureToolbarOnTop()
        recordButton?.layer.cornerRadius = (recordButton?.frame.height ?? 0) / 2
    }

    // MARK: - Toolbar Setup

    private func setupToolbar() {
        // Container bar for record button + mode selector
        toolbarView = UIView()
        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.backgroundColor = UIColor.secondarySystemBackground
        view.addSubview(toolbarView)

        NSLayoutConstraint.activate([
            toolbarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbarView.topAnchor.constraint(equalTo: view.topAnchor),
            toolbarView.heightAnchor.constraint(equalToConstant: 44)
        ])

        // --- Record button (left) ---
        recordButton = UIButton(type: .system)
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.addTarget(self, action: #selector(recordButtonTapped), for: .touchUpInside)
        recordButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        recordButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        recordButton.layer.shadowColor = UIColor.black.cgColor
        recordButton.layer.shadowOffset = CGSize(width: 0, height: 1)
        recordButton.layer.shadowOpacity = 0.15
        recordButton.layer.shadowRadius = 2
        configureButtonForIdleState()
        toolbarView.addSubview(recordButton)

        // --- Mode button (right) ---
        modeButton = UIButton(type: .system)
        modeButton.translatesAutoresizingMaskIntoConstraints = false
        modeButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        modeButton.setTitleColor(.label, for: .normal)
        modeButton.tintColor = .label
        modeButton.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        modeButton.backgroundColor = UIColor.tertiarySystemBackground
        modeButton.layer.cornerRadius = 14
        modeButton.layer.borderWidth = 0.5
        modeButton.layer.borderColor = UIColor.separator.cgColor
        modeButton.showsMenuAsPrimaryAction = true
        refreshModeButton()
        toolbarView.addSubview(modeButton)

        NSLayoutConstraint.activate([
            recordButton.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor, constant: 12),
            recordButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            recordButton.heightAnchor.constraint(equalToConstant: 32),
            recordButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),

            modeButton.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor, constant: -12),
            modeButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            modeButton.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func ensureToolbarOnTop() {
        guard let toolbar = toolbarView else { return }
        if toolbar.superview == nil { view.addSubview(toolbar) }
        view.bringSubviewToFront(toolbar)
        toolbar.layer.zPosition = 1000
    }

    // MARK: - Mode Selector

    private func refreshModeButton() {
        let modes = coordinator.getAvailableModes()
        let selectedId = coordinator.getSelectedModeId()
        let selectedName = modes.first(where: { $0.id == selectedId })?.name ?? modes.first?.name ?? "Default"

        let chevronImage = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        modeButton.setTitle(" \(selectedName) ", for: .normal)
        modeButton.setImage(chevronImage, for: .normal)
        modeButton.semanticContentAttribute = .forceRightToLeft

        // Build context menu
        var menuActions: [UIAction] = []
        for mode in modes {
            let isSelected = mode.id == selectedId || (selectedId == nil && mode.id == modes.first?.id)
            let action = UIAction(title: mode.name, state: isSelected ? .on : .off) { [weak self] _ in
                self?.coordinator.setSelectedModeId(mode.id)
                self?.refreshModeButton()
            }
            menuActions.append(action)
        }
        if menuActions.isEmpty {
            menuActions.append(UIAction(title: "Default", state: .on) { _ in })
        }
        modeButton.menu = UIMenu(children: menuActions)
    }

    // MARK: - Record Button Appearance

    private func configureButtonForIdleState() {
        let cfg = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        recordButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: cfg), for: .normal)
        recordButton.setTitle(" Record", for: .normal)
        recordButton.backgroundColor = .systemBlue
        recordButton.setTitleColor(.white, for: .normal)
        recordButton.tintColor = .white
        recordButton.semanticContentAttribute = .forceLeftToRight
    }

    private func configureButtonForRecordingState() {
        let cfg = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        recordButton.setImage(UIImage(systemName: "stop.fill", withConfiguration: cfg), for: .normal)
        recordButton.setTitle(" Stop", for: .normal)
        recordButton.backgroundColor = .systemRed
        recordButton.setTitleColor(.white, for: .normal)
        recordButton.tintColor = .white
        recordButton.semanticContentAttribute = .forceLeftToRight
    }

    // MARK: - Record Button Action

    @objc private func recordButtonTapped() {
        // Haptic feedback
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        // Press animation
        UIView.animate(withDuration: 0.08, animations: { self.recordButton.transform = CGAffineTransform(scaleX: 0.93, y: 0.93) }) { _ in
            UIView.animate(withDuration: 0.08) { self.recordButton.transform = .identity }
        }

        let isRecording = coordinator.isRecording

        if isRecording {
            coordinator.requestStopRecording()
            configureButtonForIdleState()
        } else {
            coordinator.clearOldTranscript()
            coordinator.requestStartRecording()

            // Attempt to open main app via responder chain (works on most iOS versions)
            if let url = URL(string: "voiceink://record") {
                openURLViaResponderChain(url)
            }

            configureButtonForRecordingState()
        }
    }

    /// Open a URL from the keyboard extension using the responder chain.
    /// This walks up to find a responder that handles openURL:.
    private func openURLViaResponderChain(_ url: URL) {
        let selector = sel_registerName("openURL:")
        var responder: UIResponder? = self
        while let r = responder {
            if r.responds(to: selector) {
                r.perform(selector, with: url)
                return
            }
            responder = r.next
        }
        // Fallback: show message
        showOpenAppMessage()
    }

    private func showOpenAppMessage() {
        let cfg = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        recordButton.setImage(UIImage(systemName: "app.badge", withConfiguration: cfg), for: .normal)
        recordButton.setTitle(" Open VoiceInk", for: .normal)
        recordButton.backgroundColor = .systemBlue
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.updateButtonAppearanceBasedOnState()
        }
    }

    // MARK: - State Monitoring

    private func setupRecordingStatusMonitoring() {
        recordingStatusTimer?.invalidate()
        recordingStatusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateButtonAppearanceBasedOnState()
        }
        if let t = recordingStatusTimer { RunLoop.current.add(t, forMode: .common) }
        updateButtonAppearanceBasedOnState()
        setupActivationStateObserver()
    }

    private func setupActivationStateObserver() {
        if let t = activationObserverToken {
            CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), t, nil, nil)
            activationObserverToken = nil
        }
        let token = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        activationObserverToken = token
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), token,
            { (_, observer, _, _, _) in
                guard let observer else { return }
                let vc = Unmanaged<KeyboardViewController>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { vc.updateButtonAppearanceBasedOnState() }
            },
            "com.asterayx.VoiceInk.activationStateChanged" as CFString, nil, .deliverImmediately
        )
    }

    private func updateButtonAppearanceBasedOnState() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.updateButtonAppearanceBasedOnState() }
            return
        }
        guard recordButton != nil else { return }
        if coordinator.isRecording { configureButtonForRecordingState() } else { configureButtonForIdleState() }
        recordButton.layer.cornerRadius = recordButton.frame.height / 2
    }

    // MARK: - Transcript Handling

    private func setupTranscriptNotificationObserver() {
        if let t = transcriptObserverToken {
            CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), t, nil, nil)
            transcriptObserverToken = nil
        }
        let token = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        transcriptObserverToken = token
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), token,
            { (_, observer, _, _, _) in
                guard let observer else { return }
                let vc = Unmanaged<KeyboardViewController>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { vc.handleTranscriptReady() }
            },
            "com.asterayx.VoiceInk.transcriptReady" as CFString, nil, .deliverImmediately
        )
    }

    private func handleTranscriptReady() {
        guard coordinator.isTranscriptReady,
              let transcript = coordinator.getTranscript() else { return }
        insertTranscript(transcript)
        coordinator.clearTranscript()
    }

    @discardableResult
    private func insertTranscript(_ text: String) -> Bool {
        let proxy = textDocumentProxy
        if text.count < 100 {
            proxy.insertText(text)
        } else {
            let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            for (i, word) in words.enumerated() {
                proxy.insertText((i > 0 ? " " : "") + word)
            }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        return true
    }

    // MARK: - Text Events

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            if self.coordinator.isTranscriptReady { self.handleTranscriptReady() }
        }
    }
}
