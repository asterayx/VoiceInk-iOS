import Foundation
import os.log

/// Lightweight logging utility with conditional compilation
/// Follows KISS principle - simple, focused, and easy to use
enum Logger {
    enum Level: Int, Comparable {
        case debug = 0
        case info = 1
        case warning = 2
        case error = 3
        
        static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
        
        var osLogType: OSLogType {
            switch self {
            case .debug: return .debug
            case .info: return .info
            case .warning: return .default
            case .error: return .error
            }
        }
        
        var emoji: String {
            switch self {
            case .debug: return "🔍"
            case .info: return "ℹ️"
            case .warning: return "⚠️"
            case .error: return "❌"
            }
        }
    }
    
    private static let subsystem = "com.asterayx.VoiceInk"
    private static let minimumLevel: Level = {
        #if DEBUG
        return .debug
        #else
        return .info
        #endif
    }()
    
    private static func log(_ level: Level, category: String, _ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        guard level >= minimumLevel else { return }
        
        let fileName = (file as NSString).lastPathComponent
        let logMessage = "\(level.emoji) [\(fileName):\(line)] \(function) - \(message)"
        
        #if DEBUG
        // In debug builds, use print for immediate console output
        print(logMessage)
        #else
        // In release builds, use os_log for better performance
        let osLog = OSLog(subsystem: subsystem, category: category)
        os_log("%{public}@", log: osLog, type: level.osLogType, logMessage)
        #endif
    }
    
    static func debug(_ message: String, category: String = "General", file: String = #file, function: String = #function, line: Int = #line) {
        log(.debug, category: category, message, file: file, function: function, line: line)
    }
    
    static func info(_ message: String, category: String = "General", file: String = #file, function: String = #function, line: Int = #line) {
        log(.info, category: category, message, file: file, function: function, line: line)
    }
    
    static func warning(_ message: String, category: String = "General", file: String = #file, function: String = #function, line: Int = #line) {
        log(.warning, category: category, message, file: file, function: function, line: line)
    }
    
    static func error(_ message: String, category: String = "General", file: String = #file, function: String = #function, line: Int = #line) {
        log(.error, category: category, message, file: file, function: function, line: line)
    }
}

