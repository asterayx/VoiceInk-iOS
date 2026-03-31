//
//  LibLlama.swift
//  VoiceInk-ios
//
//  Swift wrapper for llama.cpp using Objective-C++ bridge
//
//  NOTE: To use this, you must:
//  1. Add VoiceInk-ios-Bridging-Header.h to your Xcode project
//  2. In Build Settings, set "Objective-C Bridging Header" to:
//     VoiceInk-ios/VoiceInk-ios-Bridging-Header.h
//  3. Build llama.xcframework and add it to the project
//

import Foundation
import os.log

enum LlamaError: Error {
    case couldNotInitializeContext
    case modelLoadFailed
    case inferenceFailed
    case bridgeUnavailable
}

/// Swift wrapper for llama.cpp translation using Objective-C++ bridge
actor LlamaContext {
    private var bridge: LlamaBridge?
    private let logger = OSLog(subsystem: "com.asterayx.VoiceInk", category: "LlamaContext")
    
    private init() {}
    
    /// Generate text using llama.cpp
    /// - Parameters:
    ///   - prompt: The input prompt for translation
    ///   - maxTokens: Maximum number of tokens to generate (default: 256 for translation)
    /// - Returns: Generated text
    func generate(prompt: String, maxTokens: Int32 = 256) async throws -> String {
        guard let bridge = bridge else {
            os_log("LlamaContext: Bridge not initialized", log: logger, type: .error)
            throw LlamaError.couldNotInitializeContext
        }
        
        os_log("LlamaContext: Starting generation with prompt length: %d", log: logger, type: .info, prompt.count)
        
        let result = bridge.run(prompt)
        
        guard !result.isEmpty else {
            os_log("LlamaContext: Empty result from bridge", log: logger, type: .error)
            throw LlamaError.inferenceFailed
        }
        
        os_log("LlamaContext: Generated text length: %d", log: logger, type: .info, result.count)
        return result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }
    
    /// Create a new llama context with a model
    /// - Parameters:
    ///   - path: Path to the GGUF model file
    ///   - contextSize: Context window size (default: 2048 for translation)
    ///   - maxTokens: Maximum tokens to generate (default: 256)
    /// - Returns: Initialized LlamaContext
    static func createContext(
        path: String,
        contextSize: Int = 2048,
        maxTokens: Int = 256
    ) async throws -> LlamaContext {
        let llamaContext = LlamaContext()
        let logger = OSLog(subsystem: "com.asterayx.VoiceInk", category: "LlamaContext")
        
        os_log("LlamaContext: Creating context with model at %{public}@", log: logger, type: .info, path)
        
        // Initialize the Objective-C++ bridge
        let bridge = LlamaBridge(modelPath: path, context: Int32(contextSize), tokens: Int32(maxTokens))
        
        // Set bridge inside actor context
        await llamaContext.setBridge(bridge)
        os_log("LlamaContext: Context created successfully", log: logger, type: .info)
        
        return llamaContext
    }
    
    private func setBridge(_ bridge: LlamaBridge) {
        self.bridge = bridge
    }
    
    func releaseResources() {
        bridge?.releaseResources()
        bridge = nil
        os_log("LlamaContext: Resources released", log: logger, type: .info)
    }
}

