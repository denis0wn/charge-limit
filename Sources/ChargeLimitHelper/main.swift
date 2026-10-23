//
//  main.swift
//  ChargeLimitHelper
//
//  Privileged helper tool for SMJobBless - sets charge limit via PowerUI.framework
//  NO SwiftUI macros - pure Foundation/Security
//

import Foundation
import IOKit
import Security
import os.log

// MARK: - Configuration

let logger = OSLog(subsystem: "com.denissmoliakov.chargelimit.helper", category: "ChargeLimitHelper")
let powerUIPath = "/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI"

// MARK: - PowerUI Symbols

var PUIClientCreate: (@convention(c) (AnyClass?, Selector, NSString) -> AnyObject?)?
var PUIClientSetChargeLimit: (@convention(c) (AnyObject, Selector, UInt8, UnsafeMutablePointer<NSError?>?) -> Bool)?
var PUIClientGetChargeLimit: (@convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> UInt8)?

// MARK: - Load PowerUI Framework

func loadPowerUI() -> Bool {
    guard FileManager.default.fileExists(atPath: powerUIPath) else {
        os_log(.error, log: logger, "PowerUI.framework not found at %s", powerUIPath)
        return false
    }
    
    let handle = dlopen(powerUIPath, RTLD_LAZY | RTLD_LOCAL)
    guard let handle = handle else {
        let err = String(cString: dlerror())
        os_log(.error, log: logger, "dlopen failed: %s", err)
        return false
    }
    
    guard let clientClass = dlsym(handle, "OBJC_CLASS_$_PUIClient") else {
        os_log(.error, log: logger, "PUIClient class not found")
        return false
    }
    
    _ = unsafeBitCast(clientClass, to: AnyClass.self)
    
    if let sym = dlsym(handle, "PUIClientCreate") {
        PUIClientCreate = unsafeBitCast(sym, to: (@convention(c) (AnyClass?, Selector, NSString) -> AnyObject?).self)
    }
    
    os_log(.info, log: logger, "PowerUI.framework loaded successfully")
    return true
}

func createClient() -> AnyObject? {
    guard let createFunc = PUIClientCreate else {
        os_log(.error, log: logger, "PUIClientCreate not available")
        return nil
    }
    
    let clientName = "ChargeLimitHelper" as NSString
    let client = createFunc(nil, Selector(("clientWithName:")), clientName)
    
    if client == nil {
        os_log(.error, log: logger, "Client creation returned nil")
        return nil
    }
    
    if let client = client {
        let cls: AnyClass? = object_getClass(client)
        
        if let sym = class_getMethodImplementation(cls, Selector(("setChargeLimit:error:"))) {
            PUIClientSetChargeLimit = unsafeBitCast(sym, to: (@convention(c) (AnyObject, Selector, UInt8, UnsafeMutablePointer<NSError?>?) -> Bool).self)
        }
        
        if let sym = class_getMethodImplementation(cls, Selector(("getChargeLimitWithError:"))) {
            PUIClientGetChargeLimit = unsafeBitCast(sym, to: (@convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> UInt8).self)
        }
    }
    
    return client
}

// MARK: - XPC Protocol (NSXPCInterface compatible)

@objc protocol ChargeLimitXPCProtocol {
    func setChargeLimit(_ percentage: Int, reply: @escaping (NSNumber?, NSError?) -> Void)
    func getChargeLimit(_ reply: @escaping (NSNumber?, NSError?) -> Void)
}

class HelperXPCDelegate: NSObject, ChargeLimitXPCProtocol {
    func setChargeLimit(_ percentage: Int, reply: @escaping (NSNumber?, NSError?) -> Void) {
        os_log(.info, log: logger, "setChargeLimit called with %d%%", percentage)
        
        guard percentage >= 20 && percentage <= 100 else {
            let error = NSError(domain: "ChargeLimitHelper", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid limit value: \(percentage)% (must be 20-100)"])
            reply(nil, error)
            return
        }
        
        guard let client = createClient() else {
            let error = NSError(domain: "ChargeLimitHelper", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create PowerUI client"])
            reply(nil, error)
            return
        }
        
        var error: NSError?
        let success = PUIClientSetChargeLimit?(client, Selector(("setChargeLimit:error:")), UInt8(percentage), &error) ?? false
        
        if let error = error {
            os_log(.error, log: logger, "setChargeLimit failed: %s", error.localizedDescription)
            reply(nil, error)
            return
        }
        
        if !success {
            os_log(.error, log: logger, "setChargeLimit returned false")
            let err = NSError(domain: "ChargeLimitHelper", code: -3, userInfo: [NSLocalizedDescriptionKey: "PowerUI returned false"])
            reply(nil, err)
            return
        }
        
        os_log(.info, log: logger, "Successfully set charge limit to %d%%", percentage)
        reply(NSNumber(value: 1), nil)
    }
    
    func getChargeLimit(_ reply: @escaping (NSNumber?, NSError?) -> Void) {
        os_log(.info, log: logger, "getChargeLimit called")
        
        guard let client = createClient() else {
            let error = NSError(domain: "ChargeLimitHelper", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create PowerUI client"])
            reply(nil, error)
            return
        }
        
        var error: NSError?
        let limit = PUIClientGetChargeLimit?(client, Selector(("getChargeLimitWithError:")), &error) ?? 0
        
        if let error = error {
            os_log(.error, log: logger, "getChargeLimit failed: %s", error.localizedDescription)
            reply(nil, error)
            return
        }
        
        os_log(.info, log: logger, "Current charge limit: %d%%", limit)
        reply(NSNumber(value: Int(limit)), nil)
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

_ = loadPowerUI()

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: "com.denissmoliakov.ChargeLimitHelper")
listener.delegate = delegate
listener.resume()

os_log(.info, log: logger, "ChargeLimitHelper started, listening for XPC connections")

dispatchMain()