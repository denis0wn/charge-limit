//
//  ChargeLimitApp.swift
//  ChargeLimitApp
//
//  Main app entry point with manual menu bar integration.
//  Uses NSApplication delegate pattern for SPM compatibility.
//

import SwiftUI
import AppKit
import ServiceManagement

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var service: ChargeLimitService?
    private var menuBarManager: MenuBarManager?
    private var menuBarWindowController: NSWindowController?
    private var mainWindowController: NSWindowController?
    private var settingsWindowController: NSWindowController?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize services
        let service = ChargeLimitService()
        let menuBarManager = MenuBarManager()
        self.service = service
        self.menuBarManager = menuBarManager
        
        // Set activation policy to regular (show in Dock)
        NSApp.setActivationPolicy(.regular)
        
        // Setup menu bar settings callback
        menuBarManager.onOpenSettings = { [weak self] in
            self?.showSettingsWindow()
        }
        
        // Setup menu bar
        menuBarManager.setupMenuBar(service: service)
        
        // Register for sleep/wake notifications
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                NotificationCenter.default.post(name: .refreshChargeLimit, object: nil)
            }
        }
        
        // Create main window if needed
        showMainWindow()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in menu bar even when main window closed
        return false
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Show main window when dock icon clicked
        if !flag {
            showMainWindow()
        }
        return true
    }
    
    func showMainWindow() {
        if let windowController = mainWindowController, windowController.window?.isVisible == true {
            windowController.window?.makeKeyAndOrderFront(nil)
            return
        }
        
        guard let service = service, let menuBarManager = menuBarManager else { return }
        
        let contentView = ContentView(service: service, menuBarManager: menuBarManager)
        let hostingController = NSHostingController(rootView: contentView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.unifiedTitleAndToolbar)
        window.center()
        window.contentViewController = hostingController
        window.setFrameAutosaveName("MainWindow")
        window.isReleasedWhenClosed = false
        
        let windowController = NSWindowController(window: window)
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        self.mainWindowController = windowController
    }
    
    func showSettingsWindow() {
        if let windowController = settingsWindowController, windowController.window?.isVisible == true {
            windowController.window?.makeKeyAndOrderFront(nil)
            return
        }
        
        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Настройки"
        window.center()
        window.contentViewController = hostingController
        window.setFrameAutosaveName("SettingsWindow")
        window.isReleasedWhenClosed = false
        
        let windowController = NSWindowController(window: window)
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        self.settingsWindowController = windowController
    }
}

// MARK: - MenuBarManager

final class MenuBarManager: ObservableObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    var onOpenSettings: (() -> Void)?
    
    func setupMenuBar(service: ChargeLimitService) {
        // Create status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "battery.100", accessibilityDescription: "Charge Limit")
        button.image?.isTemplate = true
        button.action = #selector(togglePopover(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        
        // Create popover with menu bar view
        let menuBarView = MenuBarView(
            service: service,
            menuBarManager: self,
            onOpenSettings: { [weak self] in
                self?.onOpenSettings?()
            }
        )
        let hostingView = NSHostingView(rootView: menuBarView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 340, height: 480)
        
        popover = NSPopover()
        popover?.contentViewController = NSViewController()
        popover?.contentViewController?.view = hostingView
        popover?.behavior = .transient
        popover?.animates = true
    }
    
    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let popover = popover, let button = statusItem?.button else { return }
        
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    
    func updateIcon(enabled: Bool, limit: Int?) {
        guard let button = statusItem?.button else { return }
        
        let symbolName: String
        if enabled, let limit = limit {
            symbolName = limit <= 50 ? "battery.25" : (limit <= 80 ? "battery.50" : "battery.75")
        } else {
            symbolName = "battery.100"
        }
        
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Charge Limit")
        button.image?.isTemplate = true
        
        if enabled, let limit = limit {
            button.toolTip = "Charge Limit: \(limit)%"
        } else {
            button.toolTip = "Charge Limit: Off (100%)"
        }
    }
}

// MARK: - Main Entry Point

@main
struct ChargeLimitApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

extension Notification.Name {
    static let refreshChargeLimit = Notification.Name("refreshChargeLimit")
}