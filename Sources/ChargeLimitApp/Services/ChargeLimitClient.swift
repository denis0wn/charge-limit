// ChargeLimitClient.swift
// XPC Client for communicating with ChargeLimitHelper

import Foundation
import Security
import os.log

// MARK: - XPC Protocol

@objc protocol ChargeLimitXPCProtocol {
    func setChargeLimit(_ percentage: Int, reply: @escaping (NSNumber?, NSError?) -> Void)
    func getChargeLimit(_ reply: @escaping (NSNumber?, NSError?) -> Void)
}

// MARK: - XPC Client

final class ChargeLimitClient {
    private var connection: NSXPCConnection?
    private var proxy: ChargeLimitXPCProtocol?
    
    private let machServiceName = "com.denissmoliakov.ChargeLimitHelper"
    private let logger = OSLog(subsystem: "com.denissmoliakov.chargelimit", category: "ChargeLimitClient")
    
    // Queue for handling XPC callbacks
    private let callbackQueue = DispatchQueue(label: "com.denissmoliakov.chargelimit.xpc-callbacks", qos: .userInitiated)
    
    init() {
        setupConnection()
    }
    
    private func setupConnection() {
        let logger = self.logger
        connection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        connection?.exportedInterface = NSXPCInterface(with: ChargeLimitXPCProtocol.self)
        connection?.remoteObjectInterface = NSXPCInterface(with: ChargeLimitXPCProtocol.self)
        connection?.invalidationHandler = { [weak self] in
            os_log(.info, log: logger, "XPC connection invalidated")
            self?.proxy = nil
        }
        connection?.interruptionHandler = { [weak self] in
            os_log(.info, log: logger, "XPC connection interrupted")
            self?.proxy = nil
        }
        connection?.resume()
        proxy = connection?.remoteObjectProxyWithErrorHandler { error in
            os_log(.error, log: logger, "XPC proxy error: %@", error.localizedDescription)
        } as? ChargeLimitXPCProtocol
    }
    
    func setChargeLimit(_ percentage: Int) async throws {
        guard let proxy = proxy else {
            throw ChargeLimitError.privilegedOperationFailed("XPC proxy not available")
        }
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Add a timeout to prevent continuation leaks
            let timeoutTask = DispatchWorkItem {
                continuation.resume(throwing: ChargeLimitError.privilegedOperationFailed("XPC request timeout"))
            }
            callbackQueue.asyncAfter(deadline: .now() + 10, execute: timeoutTask)
            
            proxy.setChargeLimit(percentage) { result, error in
                timeoutTask.cancel()
                if let error = error {
                    continuation.resume(throwing: ChargeLimitError.privilegedOperationFailed(error.localizedDescription))
                } else if let result = result, result.intValue == 1 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ChargeLimitError.privilegedOperationFailed("Helper returned unexpected result"))
                }
            }
        }
    }
    
    func getChargeLimit() async throws -> Int {
        guard let proxy = proxy else {
            throw ChargeLimitError.privilegedOperationFailed("XPC proxy not available")
        }
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            // Add a timeout to prevent continuation leaks
            let timeoutTask = DispatchWorkItem {
                continuation.resume(throwing: ChargeLimitError.readFailed("XPC request timeout"))
            }
            callbackQueue.asyncAfter(deadline: .now() + 10, execute: timeoutTask)
            
            proxy.getChargeLimit { result, error in
                timeoutTask.cancel()
                if let error = error {
                    continuation.resume(throwing: ChargeLimitError.readFailed(error.localizedDescription))
                } else if let result = result {
                    continuation.resume(returning: result.intValue)
                } else {
                    continuation.resume(throwing: ChargeLimitError.readFailed("No result from helper"))
                }
            }
        }
    }
    
    func invalidate() {
        connection?.invalidate()
        connection = nil
        proxy = nil
    }
}