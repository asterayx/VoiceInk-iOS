import Foundation
import os.log

class VADModelManager {
    static let shared = VADModelManager()
    private let logger = OSLog(subsystem: "com.asterayx.VoiceInk", category: "VADModelManager")
    private var modelPath: String?

    private init() {
        if let path = Bundle.main.path(forResource: "ggml-silero-v5.1.2", ofType: "bin") {
            self.modelPath = path
            os_log("VAD model found at path: %{public}@", log: logger, type: .info, path)
        } else {
            os_log("VAD model 'ggml-silero-v5.1.2.bin' not found in bundle resources.", log: logger, type: .error)
        }
    }

    func getModelPath() -> String? {
        return modelPath
    }
}
