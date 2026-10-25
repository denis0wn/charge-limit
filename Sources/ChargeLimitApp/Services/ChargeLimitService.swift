// ChargeLimitService.swift
// ChargeLimitApp
//
// Core service for managing battery charge limits via XPC Helper
// Uses ChargeLimitClient (XPC) for privileged operations
// Falls back to osascript with admin privileges for local development
// NO SwiftUI macros - uses manual observation for SPM compilation

import Foundation
import IOKit
import IOKit.ps
import os.log

// MARK: - State Model

struct ChargeLimitState {
    let currentLimit: UInt8?
    let isEnabled: Bool
    let isSupported: Bool
    let availableUILimits: [UInt8]
    let batteryStatus: String
    let timestamp: Date
}

// MARK: - Errors

enum ChargeLimitError: LocalizedError {
    case notSupported
    case frameworkLoadFailed(String)
    case clientCreationFailed
    case readFailed(String)
    case writeFailed(String)
    case privilegedOperationFailed(String)
    case invalidLimitValue(UInt8)
    case authorizationFailed(String)
    case smcError(String)
    
    var errorDescription: String? {
        switch self {
        case .notSupported:
            return "Mac не поддерживает управление лимитом заряда (требуется Apple Silicon с поддержкой Smart Charging)"
        case .frameworkLoadFailed(let msg):
            return "Не удалось загрузить PowerUI.framework: \(msg)"
        case .clientCreationFailed:
            return "Не удалось создать клиент PowerUI"
        case .readFailed(let msg):
            return "Ошибка чтения лимита: \(msg)"
        case .writeFailed(let msg):
            return "Ошибка записи лимита: \(msg)"
        case .privilegedOperationFailed(let msg):
            return "Ошибка привилегированной операции: \(msg)"
        case .invalidLimitValue(let val):
            return "Недопустимое значение лимита: \(val)% (допустимо 20-100%)"
        case .authorizationFailed(let msg):
            return "Ошибка авторизации: \(msg)"
        case .smcError(let msg):
            return "Ошибка SMC: \(msg)"
        }
    }
}

// MARK: - ObservableObject Publisher

final class ObservableObjectPublisher {
    private var subscribers: [() -> Void] = []
    private let queue = DispatchQueue(label: "ObservableObjectPublisher", qos: .userInteractive)
    
    func subscribe(_ callback: @escaping () -> Void) {
        queue.async { self.subscribers.append(callback) }
    }
    
    func send() {
        queue.async {
            for callback in self.subscribers {
                DispatchQueue.main.async(execute: callback)
            }
        }
    }
}

// MARK: - Service (NO @MainActor, NO @Published)

final class ChargeLimitService {
    private let objectWillChange = ObservableObjectPublisher()
    var onStateChange: ((ChargeLimitState?) -> Void)?
    
    private var _state: ChargeLimitState?
    var state: ChargeLimitState? {
        get { _state }
        set { 
            _state = newValue
            objectWillChange.send()
            onStateChange?(newValue)
        }
    }
    
    private var _isLoading = false
    var isLoading: Bool {
        get { _isLoading }
        set { _isLoading = newValue; objectWillChange.send() }
    }
    
    private var _lastError: ChargeLimitError?
    var lastError: ChargeLimitError? {
        get { _lastError }
        set { _lastError = newValue; objectWillChange.send() }
    }
    
    let logger = OSLog(subsystem: "com.denissmoliakov.chargelimit", category: "ChargeLimitService")
    
    // XPC Client for communicating with privileged helper
    private var xpcClient: ChargeLimitClient?
    
    init() {
        setupXPCClient()
    }
    
    deinit {
        xpcClient?.invalidate()
    }
    
    private func setupXPCClient() {
        xpcClient = ChargeLimitClient()
    }
    
    // MARK: - Public API
    
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        lastError = nil
        
        do {
            let newState = try await readCurrentState()
            await MainActor.run { self.state = newState }
            lastError = nil
        } catch let error as ChargeLimitError {
            await MainActor.run { self.lastError = error }
            os_log(.error, log: logger, "Refresh failed: %s", error.localizedDescription)
        } catch {
            await MainActor.run { self.lastError = .readFailed(error.localizedDescription) }
        }
        
        isLoading = false
    }
    
    func setLimit(_ limit: Int) async throws {
        guard limit >= 20 && limit <= 100 else {
            throw ChargeLimitError.invalidLimitValue(UInt8(limit))
        }
        
        isLoading = true
        lastError = nil
        
        defer { isLoading = false }
        
        do {
            try await writeLimit(UInt8(limit))
            await refresh()
        } catch {
            throw error
        }
    }
    
    func disableLimit() async throws {
        isLoading = true
        lastError = nil
        
        defer { isLoading = false }
        
        do {
            try await writeLimit(100, enable: false)
            await refresh()
        } catch {
            throw error
        }
    }
    
    // MARK: - Private Implementation
    
    private func readCurrentState() async throws -> ChargeLimitState {
        let batteryStatus = await getBatteryStatusAsync()
        let isSupported = isSmartChargingSupported()
        
        if !isSupported {
            return ChargeLimitState(
                currentLimit: nil,
                isEnabled: false,
                isSupported: false,
                availableUILimits: [20, 30, 40, 50, 60, 70, 80, 90, 100],
                batteryStatus: batteryStatus,
                timestamp: Date()
            )
        }
        
        // Read from root domain via XPC helper
        var currentLimit: UInt8? = nil
        var isEnabled = false
        
        // Try to read via XPC helper first (with timeout)
        do {
            let limit = try await withTimeout(seconds: 2) { [self] in
                try await xpcClient?.getChargeLimit() ?? 100
            }
            currentLimit = UInt8(limit)
            
            // Read isManuallyChargeLimited via defaults (no admin needed for reading from root domain)
            let enabledOutput = runDefaults(args: ["read", "/Library/Preferences/com.apple.smartcharging.topoffprotection", "isManuallyChargeLimited"])
            if let enabledStr = enabledOutput, let enabledVal = Int(enabledStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
                isEnabled = enabledVal != 0
            }
        } catch {
            os_log(.error, log: logger, "Failed to read limit via XPC: %@", error.localizedDescription)
            // Fallback to defaults read (root domain - no admin needed for reading)
            let limitOutput = runDefaults(args: ["read", "/Library/Preferences/com.apple.smartcharging.topoffprotection", "mclLimitValue"])
            let enabledOutput = runDefaults(args: ["read", "/Library/Preferences/com.apple.smartcharging.topoffprotection", "isManuallyChargeLimited"])
            
            if let limitStr = limitOutput, let limit = UInt8(limitStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
                currentLimit = limit
            }
            
            if let enabledStr = enabledOutput, let enabledVal = Int(enabledStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
                isEnabled = enabledVal != 0
            }
        }
        
        return ChargeLimitState(
            currentLimit: currentLimit,
            isEnabled: isEnabled,
            isSupported: true,
            availableUILimits: [20, 30, 40, 50, 60, 70, 80, 90, 100],
            batteryStatus: batteryStatus,
            timestamp: Date()
        )
    }
    
    private func writeLimit(_ limit: UInt8, enable: Bool = true) async throws {
        guard let client = xpcClient else {
            throw ChargeLimitError.clientCreationFailed
        }
        
        os_log(.info, log: logger, "Setting charge limit to %d%%, enable=%@", limit, enable ? "true" : "false")
        
        // Try XPC first with a short timeout
        do {
            try await withTimeout(seconds: 2) {
                try await client.setChargeLimit(Int(limit))
            }
            os_log(.info, log: logger, "Successfully set charge limit to %d%% via XPC", limit)
            return
        } catch {
            os_log(.info, log: logger, "XPC unavailable or failed (%@), using osascript fallback", error.localizedDescription)
        }
        
        // Fallback to osascript with admin privileges
        try await writeViaOSAScript(limit, enable: enable)
    }
    
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ChargeLimitError.privilegedOperationFailed("Operation timed out after \(seconds)s")
            }
            
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
    
    private func writeViaOSAScript(_ limit: UInt8, enable: Bool) async throws {
        // Use osascript with admin privileges to write to root domain
        let limitStr = String(limit)
        let enableStr = enable ? "1" : "0"
        let featureStateStr = enable ? "1" : "0"
        
        // Single script with error checking - stops on first failure
        let script = """
        try
            do shell script "defaults write /Library/Preferences/com.apple.smartcharging.topoffprotection mclLimitValue -int \(limitStr)" with administrator privileges
            do shell script "defaults write /Library/Preferences/com.apple.smartcharging.topoffprotection isManuallyChargeLimited -int \(enableStr)" with administrator privileges
            do shell script "defaults write /Library/Preferences/com.apple.smartcharging.topoffprotection MCLFeatureState -int \(featureStateStr)" with administrator privileges
            do shell script "/usr/bin/notifyutil -p com.apple.smartcharging.defaultschanged" with administrator privileges
        on error errMsg number errNum
            error "Failed to write charge limit: " & errMsg & " (error " & errNum & ")"
        end try
        """
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            if task.terminationStatus != 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: data, encoding: .utf8) ?? "Unknown error"
                os_log(.error, log: logger, "OSAScript write failed: %s", errorOutput)
                throw ChargeLimitError.privilegedOperationFailed("Admin authorization failed: \(errorOutput)")
            }
            
            os_log(.info, log: logger, "Successfully wrote charge limit %d%% via osascript", limit)
        } catch let error as ChargeLimitError {
            throw error
        } catch {
            os_log(.error, log: logger, "OSAScript execution failed: %s", error.localizedDescription)
            throw ChargeLimitError.privilegedOperationFailed(error.localizedDescription)
        }
    }
    
    private func isSmartChargingSupported() -> Bool {
        // Check if we're on Apple Silicon with Smart Charging support
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("AppleSmartBattery")
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        
        guard result == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        
        let service = IOIteratorNext(iterator)
        return service != 0
    }
    
    private func getBatteryStatus() -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g", "batt"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? "Unknown"
        } catch {
            return "Error reading battery status"
        }
    }
    
    // Async version for non-blocking reads
    func getBatteryStatusAsync() async -> String {
        await Task.detached(priority: .utility) {
            self.getBatteryStatus()
        }.value
    }
    
    // Public method to get battery status without admin (uses pmset)
    func getBatteryStatusPublic() async -> String {
        return await getBatteryStatusAsync()
    }
    
    private func runDefaults(args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = args
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8)
            }
        } catch {
            os_log(.error, log: logger, "defaults read failed: %s", error.localizedDescription)
        }
        return nil
    }
    
    // MARK: - Privileged Helper (SMJobBless)
    
    func runPrivilegedHelper(arguments: [String]) async throws -> String {
        // This would integrate with SMJobBless for setting the limit
        // For now, we use the XPC helper approach
        throw ChargeLimitError.privilegedOperationFailed("XPC Helper approach used instead")
    }
}