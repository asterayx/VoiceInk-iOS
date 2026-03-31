import Foundation
#if canImport(MLKitTranslate)
@preconcurrency import MLKitTranslate
#endif

class TranslationService {
    // Singleton to ensure only one instance and prevent multiple ML Kit uploaders
    static let shared = TranslationService()
    
    #if canImport(MLKitTranslate)
    // Cache translator instances dynamically based on language pair
    // Key format: "sourceCode-targetCode" (e.g., "en-es", "es-en")
    private static var translatorCache: [String: Translator] = [:]
    private static let cacheQueue = DispatchQueue(label: "com.asterayx.VoiceInk.translatorCache")
    
    /// Get or create a translator for a specific language pair
    private func getTranslator(sourceCode: String, targetCode: String) -> Translator? {
        let key = "\(sourceCode)-\(targetCode)"
        
        return Self.cacheQueue.sync {
            if let cached = Self.translatorCache[key] {
                return cached
            }
            
            // Map language codes to ML Kit TranslateLanguage
            guard let sourceLang = mapLanguageCodeToMLKit(sourceCode),
                  let targetLang = mapLanguageCodeToMLKit(targetCode) else {
                Logger.warning("Unsupported language pair for ML Kit: \(sourceCode) → \(targetCode)", category: "TranslationService")
                return nil
            }
            
            let options = TranslatorOptions(sourceLanguage: sourceLang, targetLanguage: targetLang)
            let translator = Translator.translator(options: options)
            Self.translatorCache[key] = translator
            return translator
        }
    }
    
    /// Map language code to ML Kit TranslateLanguage enum
    private func mapLanguageCodeToMLKit(_ code: String) -> TranslateLanguage? {
        switch code.lowercased() {
        case "en": return .english
        case "es": return .spanish
        case "fr": return .french
        case "de": return .german
        case "it": return .italian
        case "pt": return .portuguese
        case "ar": return .arabic
        case "zh": return .chinese
        case "ja": return .japanese
        case "ko": return .korean
        case "ru": return .russian
        case "hi": return .hindi
        case "nl": return .dutch
        case "pl": return .polish
        case "tr": return .turkish
        case "sv": return .swedish
        case "da": return .danish
        case "no": return .norwegian
        case "fi": return .finnish
        case "cs": return .czech
        case "ro": return .romanian
        case "hu": return .hungarian
        case "el": return .greek
        case "he": return .hebrew
        case "th": return .thai
        case "vi": return .vietnamese
        case "id": return .indonesian
        case "ms": return .malay
        case "uk": return .ukrainian
        case "bg": return .bulgarian
        case "hr": return .croatian
        case "sk": return .slovak
        case "sl": return .slovenian
        case "et": return .estonian
        case "lv": return .latvian
        case "lt": return .lithuanian
        case "mt": return .maltese
        case "ga": return .irish
        case "cy": return .welsh
        case "is": return .icelandic
        case "mk": return .macedonian
        case "sq": return .albanian
        // Note: Serbian, Bosnian, and Montenegrin are not directly supported by ML Kit
        // They will fall back to LLM API translation
        case "sr", "bs", "me":
            Logger.debug("Language \(code) not directly supported by ML Kit, will use LLM API fallback", category: "TranslationService")
            return nil
        default:
            Logger.warning("Unsupported ML Kit language code: \(code)", category: "TranslationService")
            return nil
        }
    }
    #endif
    
    private let client = OpenAICompatibleClient()
    
    // Private initializer to enforce singleton pattern
    private init() {}
    
    /// Translates text from source language to target language
    /// 
    /// This uses Google ML Kit for on-device translation when available, which is free,
    /// works offline, and doesn't require API keys or external dependencies.
    /// Falls back to LLM API if ML Kit is not available or doesn't support the language pair.
    func translate(text: String, from sourceCode: String, to targetCode: String) async throws -> String {
        let sourceName = LanguageHelper.languageName(for: sourceCode)
        let targetName = LanguageHelper.languageName(for: targetCode)
        
        let systemPrompt = "You are a professional translator. Translate the following \(sourceName) text to \(targetName). Only return the \(targetName) translation, nothing else."
        let userPromptPrefix = "Translate this to \(targetName):"
        
        return try await translate(
            text: text,
            sourceLanguageCode: sourceCode,
            targetLanguageCode: targetCode,
            sourceLanguageName: sourceName,
            targetLanguageName: targetName,
            systemPrompt: systemPrompt,
            userPromptPrefix: userPromptPrefix
        )
    }
    
    /// Legacy method: Translates English text to Spanish (for backward compatibility)
    @available(*, deprecated, message: "Use translate(text:from:to:) instead")
    func translateToSpanish(text: String) async throws -> String {
        return try await translate(text: text, from: "en", to: "es")
    }
    
    /// Legacy method: Translates Spanish text to English (for backward compatibility)
    @available(*, deprecated, message: "Use translate(text:from:to:) instead")
    func translateToEnglish(text: String) async throws -> String {
        return try await translate(text: text, from: "es", to: "en")
    }
    
    // MARK: - Common Translation Logic (DRY principle)
    
    /// Common translation method that handles both ML Kit and LLM API fallback
    private func translate(
        text: String,
        sourceLanguageCode: String,
        targetLanguageCode: String,
        sourceLanguageName: String,
        targetLanguageName: String,
        systemPrompt: String,
        userPromptPrefix: String
    ) async throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Logger.warning("Empty text provided", category: "TranslationService")
            return ""
        }
        
        Logger.debug("Starting \(sourceLanguageName)→\(targetLanguageName) translation, text length: \(text.count)", category: "TranslationService")
        
        #if canImport(MLKitTranslate)
        // Try ML Kit first (on-device, offline)
        if let translator = getTranslator(sourceCode: sourceLanguageCode, targetCode: targetLanguageCode) {
            do {
                let translated = try await translateWithMLKit(text: text, translator: translator, direction: "\(sourceLanguageName)→\(targetLanguageName)")
                if !translated.isEmpty {
                    return translated
                }
                Logger.warning("ML Kit returned empty string, falling back to LLM API", category: "TranslationService")
            } catch {
                Logger.warning("ML Kit translation failed: \(error.localizedDescription), falling back to LLM API", category: "TranslationService")
            }
        } else {
            Logger.debug("ML Kit translator not available for \(sourceLanguageCode)→\(targetLanguageCode), using LLM API", category: "TranslationService")
        }
        #endif
        
        // Fallback to LLM API
        Logger.debug("Using LLM API fallback", category: "TranslationService")
        do {
            return try await translateWithLLMAPI(text: text, systemPrompt: systemPrompt, userPromptPrefix: userPromptPrefix)
        } catch {
            // Ensure error is properly propagated with context
            Logger.error("LLM API translation also failed: \(error.localizedDescription)", category: "TranslationService")
            throw TranslationError.translationFailed("Both ML Kit and LLM API translation failed. LLM API error: \(error.localizedDescription)")
        }
    }
    
    #if canImport(MLKitTranslate)
    /// Translate using ML Kit On-Device Translation (offline, free)
    /// Performance: Adds timeout to model download to fail fast and fall back to LLM API
    private func translateWithMLKit(text: String, translator: Translator, direction: String) async throws -> String {
        Logger.debug("Using ML Kit On-Device Translation (\(direction))", category: "TranslationService")
        
        // Download model if needed (with conditions)
        let conditions = ModelDownloadConditions(
            allowsCellularAccess: false, // Only download on WiFi
            allowsBackgroundDownloading: true
        )
        
        // Add timeout to model download (5 seconds) to fail fast and fall back to LLM API
        return try await withThrowingTaskGroup(of: String.self) { group in
            // Model download and translation task
            group.addTask {
                return try await withCheckedThrowingContinuation { continuation in
                    translator.downloadModelIfNeeded(with: conditions) { error in
                        if let error = error {
                            Logger.warning("ML Kit model download failed: \(error.localizedDescription)", category: "TranslationService")
                            continuation.resume(throwing: TranslationError.translationFailed("Model download failed: \(error.localizedDescription)"))
                            return
                        }
                        
                        Logger.debug("ML Kit model ready", category: "TranslationService")
                        
                        // Translate text
                        translator.translate(text) { translatedText, error in
                            if let error = error {
                                Logger.error("ML Kit translation failed: \(error.localizedDescription)", category: "TranslationService")
                                continuation.resume(throwing: TranslationError.translationFailed(error.localizedDescription))
                                return
                            }
                            
                            guard let translatedText = translatedText else {
                                continuation.resume(throwing: TranslationError.translationFailed("Translation returned nil"))
                                return
                            }
                            
                            Logger.info("ML Kit translation successful! Length: \(translatedText.count)", category: "TranslationService")
                            continuation.resume(returning: translatedText)
                        }
                    }
                }
            }
            
            // Timeout task (5 seconds for model download)
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                throw TranslationError.translationFailed("ML Kit model download timed out")
            }
            
            // Get first result (either translation or timeout)
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
    #endif
    
    /// Translate using LLM API (fallback)
    private func translateWithLLMAPI(text: String, systemPrompt: String, userPromptPrefix: String) async throws -> String {
        let settings = AppSettings.shared
        
        guard let llmConfig = settings.findAvailableLLMProvider() else {
            Logger.error("No LLM provider available for translation", category: "TranslationService")
            throw TranslationError.translatorUnavailable
        }
        
        Logger.debug("Using LLM provider: \(llmConfig.provider.rawValue), model: \(llmConfig.model)", category: "TranslationService")
        
        let userPrompt = "\(userPromptPrefix) \(text)"
        let messages = [
            OAChatMessage(role: "system", content: systemPrompt),
            OAChatMessage(role: "user", content: userPrompt)
        ]
        
        let result = try await client.chatCompletion(
            baseURL: llmConfig.provider.baseURL,
            apiKey: llmConfig.apiKey,
            model: llmConfig.model,
            messages: messages,
            temperature: 0.3
        )
        
        let translated = result.trimmingCharacters(in: .whitespacesAndNewlines)
        Logger.info("API translation successful! Length: \(translated.count)", category: "TranslationService")
        return translated
    }
}

enum TranslationError: LocalizedError {
    case translatorUnavailable
    case unsupportedVersion
    case translationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .translatorUnavailable:
            return "Translation service is not available. Please ensure your device supports translation."
        case .unsupportedVersion:
            return "Translation requires iOS 18.0 or later. Please update your device."
        case .translationFailed(let message):
            return "Translation failed: \(message)"
        }
    }
}

