// ChargeLimitService.swift
// ChargeLimitApp
//
// Core service for managing battery charge limits
// Uses SMAppService helper when available, falls back to CLI tool with sudo credential caching
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
    case helperNotInstalled
    case helperNotAuthorized
    case sudoCredentialsRequired
    
    var errorDescription: String? {
        switch self {
        case .notSupported:
            return "Mac не поддерживает управление лимитом заряда (требуется Apple Silicon с поддержкой Smart Charging)"
        case .frameworkLoadFailed(let msg):
            return "Не удалось загрузить PowerUI.framework: \(msg)"
        case .clientCreationFailed:
            return "Не удалось создать XPC клиент"
        case .readFailed(let msg):
            return "Ошибка чтения лимита: \(msg)"
        case .writeFailed(let msg):
            return "Ошибка записи лимита: \(msg)"
        case .privilegedOperationFailed(let msg):
            return "Ошибка привилегированной операции: \(msg)"
        case .invalidLimitValue(let val):
            return "Недопустимое значение лимита: \(val)% (допустимо 1-100%)"
        case .authorizationFailed(let msg):
            return "Ошибка авторизации: \(msg)"
        case .smcError(let msg):
            return "Ошибка SMC: \(msg)"
        case .helperNotInstalled:
            return "Привилегированный хелпер не установлен. Установите его в Настройках → Привилегированный хелпер."
        case .helperNotAuthorized:
            return "Хелпер требует одобрения в Настройках системы → Login Items & Extensions."
        case .sudoCredentialsRequired:
            return "Требуются права администратора. Запустите в терминале: sudo charge-limit set <значение>"
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
    
    // XPC Client for communicating with privileged helper (when available)
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
        guard limit >= 1 && limit <= 100 else {
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
                availableUILimits: Array(1...100),
                batteryStatus: batteryStatus,
                timestamp: Date()
            )
        }
        
        // Try to read via XPC helper first (with timeout)
        var currentLimit: UInt8? = nil
        var isEnabled = false
        
        do {
            let limit = try await withTimeout(seconds: 2) { [self] in
                try await xpcClient?.getChargeLimit() ?? 100
            }
            currentLimit = UInt8(limit)
            
            // Read isManuallyChargeLimited via defaults (no admin needed for reading from system domain)
            let enabledOutput = runDefaults(args: ["isManuallyChargeLimited"])
            if let enabledStr = enabledOutput, let enabledVal = Int(enabledStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
                isEnabled = enabledVal != 0
            }
        } catch {
            os_log(.error, log: logger, "Failed to read limit via XPC: %@", error.localizedDescription)
            // Fallback to CLI tool for reading (requires sudo credentials)
            do {
                let cliOutput = try await readViaCLITool()
                // Parse the CLI output to extract limit and enabled status
                let lines = cliOutput.components(separatedBy: "\n")
                for line in lines {
                    if line.contains("mclLimitValue") {
                        let parts = line.components(separatedBy: "=")
                        if parts.count >= 2 {
                            let valueStr = parts[1].trimmingCharacters(in: .whitespaces)
                            if let limit = UInt8(valueStr) {
                                currentLimit = limit
                            }
                        }
                    } else if line.contains("isManuallyChargeLimited") {
                        let parts = line.components(separatedBy: "=")
                        if parts.count >= 2 {
                            let valueStr = parts[1].trimmingCharacters(in: .whitespaces)
                            if let enabledVal = Int(valueStr) {
                                isEnabled = enabledVal != 0
                            }
                        }
                    }
                }
            } catch {
                os_log(.error, log: logger, "Failed to read limit via CLI tool: %@", error.localizedDescription)
                // Last resort: try defaults read (may not work for system domain)
                let limitOutput = runDefaults(args: ["mclLimitValue"])
                let enabledOutput = runDefaults(args: ["isManuallyChargeLimited"])
                
                if let limitStr = limitOutput, let limit = UInt8(limitStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    currentLimit = limit
                }
                
                if let enabledStr = enabledOutput, let enabledVal = Int(enabledStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    isEnabled = enabledVal != 0
                }
            }
        }
        
        return ChargeLimitState(
            currentLimit: currentLimit,
            isEnabled: isEnabled,
            isSupported: true,
            availableUILimits: Array(1...100),
            batteryStatus: batteryStatus,
            timestamp: Date()
        )
    }
    
    private func writeLimit(_ limit: UInt8, enable: Bool = true) async throws {
        // Try XPC first with a short timeout
        if let client = xpcClient {
            do {
                try await withTimeout(seconds: 5) {
                    try await client.setChargeLimit(Int(limit), enable: enable)
                }
                os_log(.info, log: logger, "Successfully set charge limit to %d%% via XPC", limit)
                return
            } catch ChargeLimitError.helperNotInstalled {
                // Fall through to fallback
            } catch ChargeLimitError.helperNotAuthorized {
                throw ChargeLimitError.helperNotAuthorized
            } catch {
                os_log(.error, log: logger, "XPC write failed: %@", error.localizedDescription)
                // Fall through to fallback
            }
        }
        
        // Fallback: Use CLI tool with sudo credential caching
        try await writeViaCLITool(limit: limit, enable: enable)
    }
    
    private func writeViaCLITool(limit: UInt8, enable: Bool) async throws {
        let toolPath = "/usr/local/bin/charge-limit"
        
        // Check if CLI tool exists
        guard FileManager.default.fileExists(atPath: toolPath) else {
            throw ChargeLimitError.privilegedOperationFailed("CLI tool not found at \(toolPath). Install charge-limit first.")
        }
        
        let args: [String]
        if enable {
            args = ["set", "\(limit)"]
        } else {
            args = ["off"]
        }
        
        os_log(.info, log: logger, "Executing CLI tool: %@ %@", toolPath, args.joined(separator: " "))
        
        // Run the CLI tool with sudo (will refresh timestamp via sudo -v)
        let output = try await runCLIToolWithSudo(toolPath: toolPath, args: args)
        os_log(.info, log: logger, "CLI tool output: %@", output)
        
        // Wait for changes to propagate
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }
    
    private func runSudoTest() async -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", "true"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
    
    private func runCLIToolWithSudo(toolPath: String, args: [String]) async throws -> String {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            task.arguments = ["-n", toolPath] + args
        
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
        
            do {
                try task.run()
                task.waitUntilExit()
            
                if task.terminationStatus != 0 {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let errorOutput = String(data: data, encoding: .utf8) ?? "Unknown error"
                    os_log(.error, log: logger, "CLI tool failed: %s", errorOutput)
                
                    // Check if failure is due to missing sudo credentials
                    if errorOutput.contains("password is required") || errorOutput.contains("a password is required") {
                        throw ChargeLimitError.sudoCredentialsRequired
                    }
                
                    throw ChargeLimitError.privilegedOperationFailed("sudo command failed: \(errorOutput)")
                }
            
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8) ?? ""
            } catch let error as ChargeLimitError {
                throw error
            } catch {
                os_log(.error, log: logger, "CLI tool execution failed: %s", error.localizedDescription)
                throw ChargeLimitError.privilegedOperationFailed("Failed to execute CLI tool: \(error.localizedDescription)")
            }
        }
    
    private func readViaCLITool() async throws -> String {
        let toolPath = "/usr/local/bin/charge-limit"
        
        guard FileManager.default.fileExists(atPath: toolPath) else {
            throw ChargeLimitError.privilegedOperationFailed("CLI tool not found at \(toolPath). Install charge-limit first.")
        }
        
        // Run the CLI tool with sudo (will refresh timestamp via sudo -v)
        let output = try await runCLIToolWithSudo(toolPath: toolPath, args: ["get"])
        os_log(.info, log: logger, "CLI tool get output: %@", output)
        return output
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
        // Read from the system domain (no path) to get the actual values
        task.arguments = ["read", "com.apple.smartcharging.topoffprotection"] + args
        
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
}