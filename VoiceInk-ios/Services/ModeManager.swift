//
//  ModeManager.swift
//  VoiceInk-ios
//
//  Mode management service extracted from AppSettings
//  Follows Single Responsibility Principle - handles mode storage and selection
//

import Foundation
import Combine

/// Manages recording modes and mode selection
@MainActor
class ModeManager: ObservableObject {
    static let shared = ModeManager()
    
    // Modes system
    @Published var modes: [Mode] {
        didSet { saveModes() }
    }
    
    @Published var selectedModeId: UUID? {
        didSet {
            if let id = selectedModeId {
                UserDefaults.standard.set(id.uuidString, forKey: "selectedModeId")
                AppGroupCoordinator.shared.setSelectedModeId(id.uuidString)
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedModeId")
                AppGroupCoordinator.shared.setSelectedModeId(nil)
            }
        }
    }
    
    var selectedMode: Mode? {
        guard let selectedModeId = selectedModeId else { return nil }
        return modes.first { $0.id == selectedModeId }
    }
    
    // Debounce saves to avoid excessive UserDefaults writes
    private var saveModesWorkItem: DispatchWorkItem?
    
    private init() {
        // Load modes
        self.modes = Self.loadModes()

        // Load selected mode
        if let selectedModeIdString = UserDefaults.standard.string(forKey: "selectedModeId"),
           let selectedModeId = UUID(uuidString: selectedModeIdString) {
            self.selectedModeId = selectedModeId
        } else {
            self.selectedModeId = nil
        }

        // Sync to App Group so keyboard extension has access
        syncModesToAppGroup()
    }
    
    deinit {
        // Ensure pending saves complete
        saveModesWorkItem?.perform()
    }
    
    // MARK: - Mode Persistence
    
    private func saveModes() {
        // Cancel any pending save
        saveModesWorkItem?.cancel()

        // Schedule save after a short delay to batch multiple rapid changes
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if let data = try? JSONEncoder().encode(self.modes) {
                UserDefaults.standard.set(data, forKey: "modes")
            }
            // Sync modes to App Group for keyboard extension access
            self.syncModesToAppGroup()
        }
        saveModesWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    /// Sync mode names/IDs to the shared App Group so the keyboard can display them
    func syncModesToAppGroup() {
        let modeInfos = modes.map { (id: $0.id.uuidString, name: $0.name) }
        AppGroupCoordinator.shared.storeModes(modeInfos)
        if let selectedId = selectedModeId {
            AppGroupCoordinator.shared.setSelectedModeId(selectedId.uuidString)
        }
    }
    
    private static func loadModes() -> [Mode] {
        guard let data = UserDefaults.standard.data(forKey: "modes"),
              let modes = try? JSONDecoder().decode([Mode].self, from: data) else {
            return []
        }
        return modes
    }
}

