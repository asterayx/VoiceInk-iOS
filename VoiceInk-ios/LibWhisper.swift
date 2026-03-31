//
//  LibWhisper.swift
//  VoiceInk-ios
//
//  Core whisper.cpp wrapper for local transcription
//

import Foundation
#if canImport(whisper)
import whisper
#else
#error("Unable to import whisper module. Please check your project configuration.")
#endif
import os.log

enum WhisperError: Error {
    case couldNotInitializeContext
}

// Meet Whisper C++ constraint: Don't access from more than one thread at a time.
actor WhisperContext {
    private var context: OpaquePointer?
    private var vadModelPath: String?
    private let logger = OSLog(subsystem: "com.asterayx.VoiceInk", category: "WhisperContext")

    private init() {}

    init(context: OpaquePointer) {
        self.context = context
    }

    deinit {
        if let context = context {
            whisper_free(context)
        }
    }

    func fullTranscribe(samples: [Float], language: String? = nil) -> Bool {
        guard let context = context else { return false }
        
        let maxThreads = max(1, min(8, cpuCount() - 2))
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        
        // Set language if provided, otherwise use auto-detection (nil)
        // Only accept "en" or "es" - restrict to English and Spanish only
        if let language = language {
            // Validate that language is either "en" or "es"
            if language == "en" || language == "es" {
                // Convert Swift String to C string for Whisper (similar to VAD model path)
                params.language = (language as NSString).utf8String
                os_log("Whisper: Using specified language: %{public}@", log: logger, type: .info, language)
            } else {
                os_log("Whisper: Invalid language '%{public}@', only 'en' and 'es' are supported. Using auto-detection instead.", log: logger, type: .default, language)
                params.language = nil
            }
        } else {
            params.language = nil
            os_log("Whisper: Using auto-detection for language (will filter to English/Spanish only)", log: logger, type: .info)
        }
        
        params.print_realtime = true
        params.print_progress = false
        params.print_timestamps = true
        params.print_special = false
        params.translate = false
        params.n_threads = Int32(maxThreads)
        params.offset_ms = 0
        params.no_context = true
        params.single_segment = false
        
        // Use lower temperature for Spanish to be more conservative with accented speech
        // This helps with non-native pronunciation
        if let lang = language, lang == "es" {
            params.temperature = 0.0  // More deterministic for Spanish
            os_log("Whisper: Using conservative temperature (0.0) for Spanish transcription", log: logger, type: .info)
        } else {
            params.temperature = 0.2  // Standard temperature for English/auto-detect
        }

        whisper_reset_timings(context)
        
        // Configure VAD
        if let vadModelPath = self.vadModelPath {
            params.vad = true
            params.vad_model_path = (vadModelPath as NSString).utf8String
            
            var vadParams = whisper_vad_default_params()
            vadParams.threshold = 0.50
            vadParams.min_speech_duration_ms = 250
            vadParams.min_silence_duration_ms = 100
            vadParams.max_speech_duration_s = Float.greatestFiniteMagnitude
            vadParams.speech_pad_ms = 30
            vadParams.samples_overlap = 0.1
            params.vad_params = vadParams
        } else {
            params.vad = false
            os_log("VAD model path not found, VAD will be disabled.", log: logger, type: .default)
        }
        
        var success = true
        samples.withUnsafeBufferPointer { samplesBuffer in
            if whisper_full(context, params, samplesBuffer.baseAddress, Int32(samplesBuffer.count)) != 0 {
                os_log("Failed to run whisper_full. VAD enabled: %d", log: logger, type: .error, params.vad ? 1 : 0)
                success = false
            }
        }
        
        return success
    }

    func getTranscription() -> String {
        guard let context = context else { return "" }
        var transcription = ""
        for i in 0..<whisper_full_n_segments(context) {
            if let text = whisper_full_get_segment_text(context, i) {
                transcription += String(cString: text)
            }
        }
        return transcription.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Get the detected language code from Whisper
    /// Only returns "en" (English) or "es" (Spanish), or nil if language could not be determined or is not English/Spanish
    func getDetectedLanguage() -> String? {
        guard let context = context else { return nil }
        
        // Whisper provides language ID after transcription
        let langId = whisper_full_lang_id(context)
        
        // Only support English and Spanish
        // Whisper language IDs: 0=en, 3=es
        switch langId {
        case 0:
            os_log("Whisper: Detected language ID %d -> English", log: logger, type: .info, langId)
            return "en"
        case 3:
            os_log("Whisper: Detected language ID %d -> Spanish", log: logger, type: .info, langId)
            return "es"
        default:
            os_log("Whisper: Detected language ID %d is not English or Spanish, returning nil", log: logger, type: .default, langId)
            return nil
        }
    }

    static func createContext(path: String) async throws -> WhisperContext {
        let whisperContext = WhisperContext()
        try await Task {
            try await whisperContext.initializeModel(path: path)
        }.value
        
        // Load VAD model from bundle resources
        let vadModelPath = VADModelManager.shared.getModelPath()
        await whisperContext.setVADModelPath(vadModelPath)
        
        return whisperContext
    }
    
    private func initializeModel(path: String) throws {
        // Check if Core ML encoder is available
        let modelDir = (path as NSString).deletingLastPathComponent
        let modelName = (path as NSString).lastPathComponent.replacingOccurrences(of: ".bin", with: "")
        let coreMLEncoderPath = (modelDir as NSString).appendingPathComponent("\(modelName)-encoder.mlmodelc")
        
        let hasCoreMLEncoder = FileManager.default.fileExists(atPath: coreMLEncoderPath)
        if hasCoreMLEncoder {
            os_log("Core ML encoder found at %{public}@ - will be used for faster transcription", log: logger, type: .info, coreMLEncoderPath)
        } else {
            os_log("Core ML encoder not found - using CPU (this is normal and works fine)", log: logger, type: .debug)
        }
        
        #if targetEnvironment(simulator)
        // Simulator doesn't support Metal GPU
        var params = whisper_context_default_params()
        params.use_gpu = false
        params.flash_attn = false
        os_log("Running on the simulator, using CPU", log: logger, type: .info)
        
        let context = whisper_init_from_file_with_params(path, params)
        if let context {
            self.context = context
            os_log("Whisper model loaded successfully with CPU (simulator)", log: logger, type: .info)
        } else {
            os_log("Couldn't load model at %{public}@", log: logger, type: .error, path)
            throw WhisperError.couldNotInitializeContext
        }
        #else
        // Try Metal GPU first for better performance, fall back to CPU if it fails
        var gpuParams = whisper_context_default_params()
        gpuParams.use_gpu = true
        gpuParams.flash_attn = false
        
        os_log("Attempting to initialize Whisper with Metal GPU acceleration", log: logger, type: .info)
        
        // Try GPU first
        if let gpuContext = whisper_init_from_file_with_params(path, gpuParams) {
            self.context = gpuContext
            if hasCoreMLEncoder {
                os_log("Whisper model loaded successfully with Metal GPU + Core ML encoder", log: logger, type: .info)
            } else {
                os_log("Whisper model loaded successfully with Metal GPU acceleration", log: logger, type: .info)
            }
            return
        }
        
        // GPU failed, fall back to CPU
        os_log("Metal GPU initialization failed, falling back to CPU", log: logger, type: .default)
        
        var cpuParams = whisper_context_default_params()
        cpuParams.use_gpu = false
        cpuParams.flash_attn = false
        
        let context = whisper_init_from_file_with_params(path, cpuParams)
        if let context {
            self.context = context
            if hasCoreMLEncoder {
                os_log("Whisper model loaded successfully with CPU + Core ML encoder (GPU unavailable)", log: logger, type: .info)
            } else {
                os_log("Whisper model loaded successfully with CPU (GPU unavailable)", log: logger, type: .info)
            }
        } else {
            os_log("Couldn't load model at %{public}@ (both GPU and CPU failed)", log: logger, type: .error, path)
            throw WhisperError.couldNotInitializeContext
        }
        #endif
    }
    
    private func setVADModelPath(_ path: String?) {
        self.vadModelPath = path
        if path != nil {
            os_log("VAD model loaded from bundle resources", log: logger, type: .info)
        }
    }

    func releaseResources() {
        if let context = context {
            whisper_free(context)
            self.context = nil
        }
    }
}

fileprivate func cpuCount() -> Int {
    ProcessInfo.processInfo.processorCount
}


