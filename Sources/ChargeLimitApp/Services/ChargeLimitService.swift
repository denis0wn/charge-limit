//
//  ChargeLimitService.swift
//  ChargeLimitApp
//
//  Core service for managing battery charge limits via PowerUI.framework
//  NO SwiftUI macros - uses manual observation for SPM compilation
//

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
            return "Mac не поддерживает управление лимитом заряда (требуется Apple Silicon с поддержкой MCL)"
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
    let powerUIPath = "/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI"
    private var powerUIHandle: UnsafeMutableRawPointer?
    
    // PowerUI symbols
    private var PUIClientCreate: (@convention(c) (AnyClass?, Selector, NSString) -> AnyObject?)?
    private var PUIClientCopySupportedChargeLimits: (@convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> AnyObject?)?
    private var PUIClientGetChargeLimit: (@convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> UInt8)?
    private var PUIClientSetChargeLimit: (@convention(c) (AnyObject, Selector, UInt8, UnsafeMutablePointer<NSError?>?) -> Bool)?
    private var PUIClientIsMCLSupported: (@convention(c) (AnyObject, Selector) -> Bool)?
    private var PUIClientIsMCLCurrentlyEnabled: (@convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> UInt64)?
    
    init() {
        loadPowerUIFramework()
    }
    
    deinit {
        if let handle = powerUIHandle {
            dlclose(handle)
        }
    }
    
    // MARK: - Framework Loading
    
    private func loadPowerUIFramework() {
        guard FileManager.default.fileExists(atPath: powerUIPath) else {
            os_log(.error, log: logger, "PowerUI.framework not found at %s", powerUIPath)
            return
        }
        
        let handle = dlopen(powerUIPath, RTLD_LAZY | RTLD_LOCAL)
        guard let handle = handle else {
            let err = String(cString: dlerror())
            os_log(.error, log: logger, "dlopen failed: %s", err)
            lastError = .frameworkLoadFailed(err)
            return
        }
        
        powerUIHandle = handle
        
        // Load symbols
        guard let clientClass = dlsym(handle, "OBJC_CLASS_$_PUIClient") else {
            os_log(.error, log: logger, "PUIClient class not found")
            lastError = .frameworkLoadFailed("PUIClient class not found")
            return
        }
        
        _ = unsafeBitCast(clientClass, to: AnyClass.self)  // suppress unused warning
        
        // PUIClientCreate
        if let sym = dlsym(handle, "PUIClientCreate") {
            PUIClientCreate = unsafeBitCast(sym, to: (@convention(c) (AnyClass?, Selector, NSString) -> AnyObject?).self)
        }
        
        os_log(.info, log: logger, "PowerUI.framework loaded successfully")
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
            // Write to root domain via privileged command
            let script = """
                do shell script "defaults write com.apple.smartcharging.topoffprotection mclLimitValue -int 100; defaults write com.apple.smartcharging.topoffprotection isManuallyChargeLimited -int 0; defaults write com.apple.smartcharging.topoffprotection MCLFeatureState -int 1; notifyutil -p com.apple.smartcharging.defaultschanged" with administrator privileges
            """
            
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script]
            
            let pipe = Pipe()
            task.standardOutput = pipe
            let errorPipe = Pipe()
            task.standardError = errorPipe
            
            try task.run()
            task.waitUntilExit()
            
            if task.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorMsg = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                throw ChargeLimitError.writeFailed(errorMsg)
            }
            
            // Wait for the change to take effect
            try await Task.sleep(nanoseconds: 4_000_000_000)
            
            await refresh()
        } catch {
            throw error
        }
    }
    
    // MARK: - Private Implementation
    
    private func createClient() -> AnyObject? {
        guard let createFunc = PUIClientCreate else {
            os_log(.error, log: logger, "PUIClientCreate not available")
            return nil
        }
        
        let clientName = "ChargeLimitApp" as NSString
        let client = createFunc(nil, Selector(("clientWithName:")), clientName)
        
        if client == nil {
            os_log(.error, log: logger, "Client creation returned nil")
            return nil
        }
        
        // Resolve instance methods
        if let client = client {
            resolveInstanceMethods(for: client)
        }
        
        return client
    }
    
    private func resolveInstanceMethods(for client: AnyObject) {
        let cls: AnyClass? = object_getClass(client)
        
        if let sym = class_getMethodImplementation(cls, Selector(("copySupportedChargeLimitsWithError:"))) {
            PUIClientCopySupportedChargeLimits = unsafeBitCast(sym, to: (@convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> AnyObject?).self)
        }
        
        if let sym = class_getMethodImplementation(cls, Selector(("getChargeLimitWithError:"))) {
            PUIClientGetChargeLimit = unsafeBitCast(sym, to: (@convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> UInt8).self)
        }
        
        if let sym = class_getMethodImplementation(cls, Selector(("setChargeLimit:error:"))) {
            PUIClientSetChargeLimit = unsafeBitCast(sym, to: (@convention(c) (AnyObject, Selector, UInt8, UnsafeMutablePointer<NSError?>?) -> Bool).self)
        }
        
        if let sym = class_getMethodImplementation(cls, Selector(("isMCLSupported"))) {
            PUIClientIsMCLSupported = unsafeBitCast(sym, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
        }
        
        if let sym = class_getMethodImplementation(cls, Selector(("isMCLCurrentlyEnabledWithError:"))) {
            PUIClientIsMCLCurrentlyEnabled = unsafeBitCast(sym, to: (@convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> UInt64).self)
        }
    }
    
    private func readCurrentState() async throws -> ChargeLimitState {
        let batteryStatus = getBatteryStatus()
        
        // Read limit from root domain via privileged command
        var mclLimit: Int? = nil
        var isManuallyLimited = false
        var featureState = 0
        
        // Use sudo defaults read via osascript
        let readScript = """
            do shell script "defaults read com.apple.smartcharging.topoffprotection mclLimitValue" with administrator privileges
        """
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", readScript]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let val = Int(str) {
                mclLimit = val
            }
        } catch {
            os_log(.error, log: logger, "Failed to read mclLimitValue: %s", error.localizedDescription)
        }
        
        // Read isManuallyChargeLimited
        let readScript2 = """
            do shell script "defaults read com.apple.smartcharging.topoffprotection isManuallyChargeLimited" with administrator privileges
        """
        
        let task2 = Process()
        task2.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task2.arguments = ["-e", readScript2]
        
        let pipe2 = Pipe()
        task2.standardOutput = pipe2
        task2.standardError = Pipe()
        
        do {
            try task2.run()
            task2.waitUntilExit()
            let data = pipe2.fileHandleForReading.readDataToEndOfFile()
            if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let val = Int(str) {
                isManuallyLimited = (val != 0)
            }
        } catch {
            os_log(.error, log: logger, "Failed to read isManuallyChargeLimited: %s", error.localizedDescription)
        }
        
        let isEnabled = isManuallyLimited && (mclLimit != nil)
        let limit = mclLimit ?? 100
        
        return ChargeLimitState(
            currentLimit: UInt8(limit),
            isEnabled: isEnabled,
            isSupported: true,
            availableUILimits: [20, 30, 40, 50, 60, 70, 80, 90, 100],
            batteryStatus: batteryStatus,
            timestamp: Date()
        )
    }
    
    private func writeLimit(_ limit: UInt8) async throws {
        // Write to root domain via privileged command
        let script = """
            do shell script "defaults write com.apple.smartcharging.topoffprotection mclLimitValue -int \(limit); defaults write com.apple.smartcharging.topoffprotection isManuallyChargeLimited -int 1; defaults write com.apple.smartcharging.topoffprotection MCLFeatureState -int 1; notifyutil -p com.apple.smartcharging.defaultschanged" with administrator privileges
        """
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        let errorPipe = Pipe()
        task.standardError = errorPipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            if task.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorMsg = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                throw ChargeLimitError.writeFailed(errorMsg)
            }
        } catch let error as ChargeLimitError {
            throw error
        } catch {
            throw ChargeLimitError.writeFailed(error.localizedDescription)
        }
        
        // Wait for the change to take effect
        try await Task.sleep(nanoseconds: 4_000_000_000)
        
        os_log(.info, log: logger, "Successfully set charge limit to %d%%", limit)
    }
    
    private func isMCLSupported() -> Bool {
        // Check if we're on Apple Silicon with battery
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
    
    // MARK: - Privileged Helper (SMJobBless)
    
    func runPrivilegedHelper(arguments: [String]) async throws -> String {
        // This would integrate with SMJobBless for setting the limit
        // For now, we use the direct PowerUI approach which requires
        // the app to have appropriate entitlements or run as root
        throw ChargeLimitError.privilegedOperationFailed("SMJobBless not yet implemented")
    }
}