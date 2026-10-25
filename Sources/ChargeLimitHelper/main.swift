//
//  main.swift
//  ChargeLimitHelper
//
//  Privileged helper tool for SMAppService - sets charge limit via system preferences
//  Uses the same mechanism as the charge-limit CLI: defaults write + notifyutil
//  NO SwiftUI macros - pure Foundation/Security
//

import Foundation
import IOKit
import Security
import os.log

// MARK: - Configuration

let logger = OSLog(subsystem: "com.denissmoliakov.chargelimit.helper", category: "ChargeLimitHelper")
let domain = "com.apple.smartcharging.topoffprotection"
let notifyName = "com.apple.smartcharging.defaultschanged"
let prefsPath = "/Library/Preferences/\(domain).plist"

// MARK: - XPC Protocol (NSXPCInterface compatible)

@objc protocol ChargeLimitXPCProtocol {
    func setChargeLimit(_ percentage: Int, enable: Bool, reply: @escaping (NSNumber?, NSError?) -> Void)
    func getChargeLimit(_ reply: @escaping (NSNumber?, NSError?) -> Void)
}

class HelperXPCDelegate: NSObject, ChargeLimitXPCProtocol {
    func setChargeLimit(_ percentage: Int, enable: Bool, reply: @escaping (NSNumber?, NSError?) -> Void) {
        os_log(.info, log: logger, "setChargeLimit called with %d%%, enable=%@", percentage, enable ? "true" : "false")
        
        guard percentage >= 1 && percentage <= 100 else {
            let error = NSError(domain: "ChargeLimitHelper", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid limit value: \(percentage)% (must be 1-100)"])
            reply(nil, error)
            return
        }
        
        // Write to root domain preferences
        let result = writePreferences(limit: percentage, enable: enable)
        
        switch result {
        case .success:
            os_log(.info, log: logger, "Successfully set charge limit to %d%%, enable=%@", percentage, enable ? "true" : "false")
            reply(NSNumber(value: 1), nil)
        case .failure(let error):
            os_log(.error, log: logger, "setChargeLimit failed: %s", error.localizedDescription)
            reply(nil, error)
        }
    }
    
    func getChargeLimit(_ reply: @escaping (NSNumber?, NSError?) -> Void) {
        os_log(.info, log: logger, "getChargeLimit called")
        
        let limit = readLimitFromPrefs()
        os_log(.info, log: logger, "Current charge limit: %d%%", limit)
        reply(NSNumber(value: Int(limit)), nil)
    }
    
    private enum WriteResult {
        case success
        case failure(NSError)
    }
    
    private func writePreferences(limit: Int, enable: Bool) -> WriteResult {
        // Write mclLimitValue
        let limitResult = runDefaults(args: ["write", prefsPath, "mclLimitValue", "-int", "\(limit)"])
        if !limitResult {
            return .failure(NSError(domain: "ChargeLimitHelper", code: -10, userInfo: [NSLocalizedDescriptionKey: "Failed to write mclLimitValue"]))
        }
        
        // Write isManuallyChargeLimited
        let enableValue = enable ? "1" : "0"
        let enableResult = runDefaults(args: ["write", prefsPath, "isManuallyChargeLimited", "-int", enableValue])
        if !enableResult {
            return .failure(NSError(domain: "ChargeLimitHelper", code: -11, userInfo: [NSLocalizedDescriptionKey: "Failed to write isManuallyChargeLimited"]))
        }
        
        // Write MCLFeatureState
        let featureStateValue = enable ? "1" : "0"
        let featureResult = runDefaults(args: ["write", prefsPath, "MCLFeatureState", "-int", featureStateValue])
        if !featureResult {
            return .failure(NSError(domain: "ChargeLimitHelper", code: -12, userInfo: [NSLocalizedDescriptionKey: "Failed to write MCLFeatureState"]))
        }
        
        // Post Darwin notification
        let notifyResult = runNotifyUtil()
        if !notifyResult {
            return .failure(NSError(domain: "ChargeLimitHelper", code: -13, userInfo: [NSLocalizedDescriptionKey: "Failed to post Darwin notification"]))
        }
        
        return .success
    }
    
    private func readLimitFromPrefs() -> Int {
        let output = runDefaultsWithOutput(args: ["read", prefsPath, "mclLimitValue"])
        if let output = output, let limit = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return limit
        }
        return 100
    }
    
    private func runDefaults(args: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = args
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            os_log(.error, log: logger, "defaults write failed: %s", error.localizedDescription)
            return false
        }
    }
    
    private func runDefaultsWithOutput(args: [String]) -> String? {
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
    
    private func runNotifyUtil() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/notifyutil")
        task.arguments = ["-p", notifyName]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            os_log(.error, log: logger, "notifyutil failed: %s", error.localizedDescription)
            return false
        }
    }
}

// MARK: - XPC Listener

class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let helper = HelperXPCDelegate()
        newConnection.exportedInterface = NSXPCInterface(with: ChargeLimitXPCProtocol.self)
        newConnection.exportedObject = helper
        newConnection.resume()
        os_log(.info, log: logger, "Accepted new XPC connection")
        return true
    }
}

// MARK: - Main

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: "com.denissmoliakov.ChargeLimitHelper")
listener.delegate = delegate
listener.resume()

os_log(.info, log: logger, "ChargeLimitHelper started, listening for XPC connections")

dispatchMain()