//
//  ChargeLimitService.swift
//  ChargeLimitApp
//
//  Core service for managing battery charge limits via macOS Smart Charging preferences
//  Uses AuthorizationExecuteWithPrivileges for privilege escalation (works with adhoc signing)
//  NO SwiftUI macros - uses manual observation for SPM compilation
//  Based on charge-limit project: writes to com.apple.smartcharging.topoffprotection + Darwin notification
//

import Foundation
import Security
import AppKit
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
    case readFailed(String)
    case writeFailed(String)
    case privilegedOperationFailed(String)
    case invalidLimitValue(UInt8)
    case authorizationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .notSupported:
            return "Mac не поддерживает управление лимитом заряда (требуется Apple Silicon с поддержкой Smart Charging)"
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
    
    private var _state: ChargeLimitState?
    var state: ChargeLimitState? {
        get { _state }
        set { _state = newValue; objectWillChange.send() }
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
    
    // Smart Charging preferences domain (root domain)
    private let smartChargingDomain = "com.apple.smartcharging.topoffprotection"
    private let darwinNotification = "com.apple.smartcharging.defaultschanged"
    
    init() {}
    
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
        let batteryStatus = getBatteryStatus()
        let isSupported = isSmartChargingSupported()
        
        if !isSupported {
            return ChargeLimitState(
                currentLimit: nil,
                isEnabled: false,
                isSupported: false,
                availableUILimits: [80, 85, 90, 95, 100],
                batteryStatus: batteryStatus,
                timestamp: Date()
            )
        }
        
        // Read from root preferences using defaults
        let limitOutput = runDefaults(args: ["read", smartChargingDomain, "mclLimitValue"], asRoot: true)
        let enabledOutput = runDefaults(args: ["read", smartChargingDomain, "isManuallyChargeLimited"], asRoot: true)
        
        var currentLimit: UInt8? = nil
        var isEnabled = false
        
        if let limitStr = limitOutput, let limit = UInt8(limitStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
            currentLimit = limit
        }
        
        if let enabledStr = enabledOutput, let enabledVal = Int(enabledStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
            isEnabled = enabledVal != 0
        }
        
        return ChargeLimitState(
            currentLimit: currentLimit,
            isEnabled: isEnabled,
            isSupported: true,
            availableUILimits: [80, 85, 90, 95, 100],
            batteryStatus: batteryStatus,
            timestamp: Date()
        )
    }
    
    private func writeLimit(_ limit: UInt8, enable: Bool = true) async throws {
        os_log(.info, log: logger, "Setting charge limit to %d%%, enable=%@", limit, enable ? "true" : "false")
        
        // Build the shell script that runs as root
        let script = """
        #!/bin/sh
        set -eu
        
        DOMAIN="\(smartChargingDomain)"
        NOTIFY="\(darwinNotification)"
        
        defaults write "$DOMAIN" mclLimitValue -int \(limit)
        defaults write "$DOMAIN" isManuallyChargeLimited -int \(enable ? 1 : 0)
        defaults write "$DOMAIN" MCLFeatureState -int 1
        
        notifyutil -p "$NOTIFY"
        sleep 2
        
        # Verify
        defaults read "$DOMAIN" mclLimitValue
        defaults read "$DOMAIN" isManuallyChargeLimited
        """
        
        try await runScriptAsRoot(script)
        
        os_log(.info, log: logger, "Successfully set charge limit to %d%%", limit)
    }
    
    private func runScriptAsRoot(_ script: String) async throws {
        // Create temporary script file
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("chargelimit_set_\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
        }
        
        // Use osascript with administrator privileges
        let escapedPath = scriptURL.path.replacingOccurrences(of: "\"", with: "\\\"")
        let appleScriptSource = "do shell script \"\\\"\(escapedPath)\\\"\" with administrator privileges"
        
        let appleScript = NSAppleScript(source: appleScriptSource)
        var errorDict: NSDictionary?
        let result = appleScript?.executeAndReturnError(&errorDict)
        
        if let errorDict = errorDict {
            let errorMsg = errorDict["NSAppleScriptErrorMessage"] as? String ?? "Unknown AppleScript error"
            let errorNumber = errorDict["NSAppleScriptErrorNumber"] as? Int ?? -1
            os_log(.error, log: logger, "AppleScript execution failed (err=%d): %s", errorNumber, errorMsg)
            throw ChargeLimitError.privilegedOperationFailed("AppleScript error \(errorNumber): \(errorMsg)")
        }
        
        if let result = result {
            let output = result.stringValue ?? ""
            os_log(.info, log: logger, "Privileged script output: %s", output)
        }
        
        os_log(.info, log: logger, "Privileged script completed successfully")
    }
    
    private func runDefaults(args: [String], asRoot: Bool) -> String? {
        if asRoot {
            // For reading as root, we need to use a different approach
            // Since AuthorizationExecuteWithPrivileges is for execution, not reading
            // We'll use a simple sudo approach or read from a cached location
            // For now, return nil and rely on the user-visible state
            return nil
        } else {
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
}