// ContentView.swift
// Premium main window WITHOUT SwiftUI property wrapper macros
// Uses manual state management via ContentViewModel

import SwiftUI
import Combine

// MARK: - ContentViewModel (NO @Published, NO @ObservableObject macro)

final class ContentViewModel {
    // State
    var backgroundPhase: CGFloat = 0 { didSet { objectWillChange.send() } }
    var showSettings = false { didSet { objectWillChange.send() } }
    var selectedLimit: Int = 80 { didSet { objectWillChange.send() } }
    var isApplying: Bool = false { didSet { objectWillChange.send() } }
    var authError: String? = nil { didSet { objectWillChange.send() } }
    var showingAuthAlert: Bool = false { didSet { objectWillChange.send() } }
    
    let objectWillChange = ObservableObjectPublisher()
    
    let service: ChargeLimitService
    let menuBarManager: MenuBarManager
    
    // Battery animation states
    let heroBatteryState = BatteryViewState()
    let limitIndicatorBatteryState = BatteryViewState()
    
    // Shared component states (from SharedComponents)
    let sliderDragState = SliderDragState()
    let presetPressState = PressState()
    
    init(service: ChargeLimitService, menuBarManager: MenuBarManager) {
        self.service = service
        self.menuBarManager = menuBarManager
        
        // Start background animation
        startBackgroundAnimation()
        
        // Observe service changes
        service.onStateChange = { [weak self] _ in
            Task { @MainActor in
                self?.updateFromService()
            }
        }
    }
    
    private func startBackgroundAnimation() {
        withAnimation(.linear(duration: 30).repeatForever(autoreverses: false)) {
            backgroundPhase = 2 * .pi
        }
    }
    
    private func updateFromService() {
        selectedLimit = currentLimit
        
        // Update battery states
        let charge = currentChargeLevel
        let charging = isCharging
        let limited = isLimitEnabled
        let limit = currentLimit
        
        heroBatteryState.configure(
            chargeLevel: charge,
            isCharging: charging,
            isLimited: limited,
            limitPercent: limited ? limit : nil,
            size: .large,
            animated: true
        )
        
        limitIndicatorBatteryState.configure(
            chargeLevel: charge,
            isCharging: charging,
            isLimited: limited,
            limitPercent: limited ? limit : nil,
            size: .medium,
            animated: false
        )
    }
    
    var currentChargeLevel: Double {
        let status = service.state?.batteryStatus ?? ""
        let pattern = #"(\d+)%"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: status, range: NSRange(location: 0, length: status.utf16.count)),
           let range = Range(match.range(at: 1), in: status) {
            return Double(status[range]) ?? 0
        }
        return 0
    }
    
    var isCharging: Bool {
        let status = service.state?.batteryStatus ?? ""
        return status.contains("AC attached") && !status.contains("discharging")
    }
    
    var currentLimit: Int {
        service.state?.currentLimit.map(Int.init) ?? 80
    }
    
    var isLimitEnabled: Bool {
        service.state?.isEnabled ?? false
    }
    
    var batteryHealth: String {
        "Хорошее"
    }
    
    var chargeWatts: String {
        let status = service.state?.batteryStatus ?? ""
        if let range = status.range(of: #"(\d+\.?\d*)\s*W"#, options: .regularExpression) {
            return String(status[range])
        }
        return "—"
    }
    
    var timeRemaining: String {
        let status = service.state?.batteryStatus ?? ""
        if let range = status.range(of: #"(\d+:\d+)"#) {
            return String(status[range])
        }
        return isCharging ? "Расчёт..." : "—"
    }
    
    func isValidLimit(_ limit: Int) -> Bool {
        limit >= 20 && limit <= 100
    }
    
    func setLimit(_ limit: Int) {
        selectedLimit = limit
    }
    
    func toggleLimit(_ enabled: Bool) {
        if !enabled {
            Task {
                do {
                    try await service.disableLimit()
                    await MainActor.run {
                        selectedLimit = 100
                        menuBarManager.updateIcon(enabled: false, limit: nil)
                        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                    }
                } catch {
                    await MainActor.run {
                        authError = error.localizedDescription
                        showingAuthAlert = true
                    }
                }
            }
        }
    }
    
    func applyLimit() {
        guard isValidLimit(selectedLimit) else { return }
        isApplying = true
        
        Task {
            do {
                try await service.setLimit(selectedLimit)
                await MainActor.run {
                    isApplying = false
                    menuBarManager.updateIcon(enabled: true, limit: selectedLimit)
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                }
            } catch {
                await MainActor.run {
                    isApplying = false
                    authError = error.localizedDescription
                    showingAuthAlert = true
                }
            }
        }
    }
    
    func disableLimit() {
        isApplying = true
        
        Task {
            do {
                try await service.disableLimit()
                await MainActor.run {
                    selectedLimit = 100
                    isApplying = false
                    menuBarManager.updateIcon(enabled: false, limit: nil)
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                }
            } catch {
                await MainActor.run {
                    isApplying = false
                    authError = error.localizedDescription
                    showingAuthAlert = true
                }
            }
        }
    }
    
    func refresh() {
        Task { await service.refresh() }
    }
    
    func openSettings() {
        showSettings = true
    }
}

// MARK: - ContentView (NO @StateObject, NO @State, NO @ObservedObject)

struct ContentView: View {
    let viewModel: ContentViewModel
    
    init(service: ChargeLimitService, menuBarManager: MenuBarManager) {
        self.viewModel = ContentViewModel(service: service, menuBarManager: menuBarManager)
    }
    
    var body: some View {
        ZStack {
            AnimatedBackground(phase: viewModel.backgroundPhase)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                TopBarView(
                    onSettings: { viewModel.openSettings() },
                    onQuit: { NSApp.terminate(nil) }
                )
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 8)
                
                ScrollView {
                    VStack(spacing: 24) {
                        // Hero Battery Section
                        HeroBatterySection(viewModel: viewModel)
                        
                        // Control Section
                        ControlSection(viewModel: viewModel)
                        
                        // Quick Presets
                        ContentQuickPresetsSection(viewModel: viewModel)
                        
                        // Action Buttons
                        ContentActionButtonsSection(viewModel: viewModel)
                        
                        // Battery Info
                        BatteryInfoSection(viewModel: viewModel)
                        
                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                }
            }
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 720, idealHeight: 800)
        .onAppear {
            viewModel.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshChargeLimit)) { _ in
            viewModel.refresh()
        }
        .sheet(isPresented: Binding(
            get: { viewModel.showSettings },
            set: { viewModel.showSettings = $0 }
        )) {
            SettingsView()
                .frame(width: 520, height: 620)
        }
        .alert("Ошибка", isPresented: Binding(
            get: { viewModel.showingAuthAlert },
            set: { viewModel.showingAuthAlert = $0 }
        ), presenting: viewModel.authError) { _ in
            Button("OK") { viewModel.authError = nil }
        } message: { error in
            Text(error)
        }
    }
}

// MARK: - Hero Battery Section

struct HeroBatterySection: View {
    let viewModel: ContentViewModel
    
    var body: some View {
        VStack(spacing: 16) {
            // Main battery
            BatteryView(
                chargeLevel: viewModel.currentChargeLevel,
                isCharging: viewModel.isCharging,
                isLimited: viewModel.isLimitEnabled,
                limitPercent: viewModel.isLimitEnabled ? viewModel.currentLimit : nil,
                size: .large,
                animated: true,
                state: viewModel.heroBatteryState
            )
            
            // Status badges
            HStack(spacing: 12) {
                StatusBadge(
                    icon: viewModel.isLimitEnabled ? "checkmark.shield.fill" : "shield.slash.fill",
                    text: viewModel.isLimitEnabled ? "Лимит: \(viewModel.currentLimit)%" : "Лимит отключён",
                    color: viewModel.isLimitEnabled ? .blue : .orange,
                    isActive: viewModel.isLimitEnabled
                )
                
                StatusPill(
                    text: "\(Int(viewModel.currentChargeLevel))%",
                    icon: viewModel.isCharging ? "bolt.fill" : "battery.100",
                    color: viewModel.isCharging ? .yellow : .green
                )
                
                StatusPill(
                    text: viewModel.batteryHealth,
                    icon: "heart.fill",
                    color: .red
                )
                
                Spacer()
            }
        }
    }
}

// MARK: - Control Section

struct ControlSection: View {
    let viewModel: ContentViewModel
    
    var body: some View {
        VStack(spacing: 16) {
            // Toggle row
            PremiumToggleRow(
                icon: "slider.horizontal.3",
                title: "Лимит заряда",
                subtitle: "Остановить зарядку на заданном проценте (20–100%)",
                isOn: viewModel.isLimitEnabled,
                color: .blue,
                onToggle: { viewModel.toggleLimit($0) }
            )
            
            // Slider (when enabled)
            if viewModel.isLimitEnabled {
                VStack(spacing: 12) {
                    HStack {
                        Text("Максимальный заряд")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(viewModel.currentLimit)%")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(.blue)
                            .contentTransition(.numericText())
                    }
                    
                    PremiumSlider(
                        value: Double(viewModel.currentLimit),
                        range: 20...100,
                        step: 5,
                        activeColor: .blue,
                        trackColor: Color.blue.opacity(0.15),
                        onChange: { viewModel.setLimit(Int($0)) },
                        dragState: viewModel.sliderDragState
                    )
                    .frame(height: 44)
                }
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.blue.opacity(0.15), lineWidth: 1)
                )
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.95).combined(with: .opacity).combined(with: .offset(y: -10)),
                    removal: .scale(scale: 0.95).combined(with: .opacity).combined(with: .offset(y: -10))
                ))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewModel.isLimitEnabled)
    }
}

// MARK: - Battery Info Section

struct BatteryInfoSection: View {
    let viewModel: ContentViewModel
    
    var body: some View {
        VStack(spacing: 16) {
            // Limit indicator battery
            VStack(spacing: 10) {
                HStack {
                    Text("Индикатор лимита")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                
                BatteryView(
                    chargeLevel: viewModel.currentChargeLevel,
                    isCharging: viewModel.isCharging,
                    isLimited: viewModel.isLimitEnabled,
                    limitPercent: viewModel.isLimitEnabled ? viewModel.currentLimit : nil,
                    size: .medium,
                    animated: false,
                    state: viewModel.limitIndicatorBatteryState
                )
            }
            
            // Info cards
            HStack(spacing: 14) {
                InfoCard(
                    icon: "bolt.fill",
                    title: "Мощность заряда",
                    description: viewModel.chargeWatts,
                    color: .yellow
                )
                
                InfoCard(
                    icon: "clock.fill",
                    title: "Оставшееся время",
                    description: viewModel.timeRemaining,
                    color: .purple
                )
            }
            
            // Technical details
            InfoCard(
                icon: "cpu.fill",
                title: "Техническая информация",
                description: """
                    • Механизм: PowerUI.framework + SMC fallback
                    • Привилегии: NSAppleScript (admin prompt)
                    • Домен: com.apple.smartcharging.topoffprotection
                    • Уведомление: com.apple.smartcharging.defaultschanged
                    • Ключи SMC: CHLC (current), BCLM (max)
                    • Архитектура: SPM, macOS 14+, Apple Silicon / Intel
                    """,
                color: .blue
            )
        }
    }
}