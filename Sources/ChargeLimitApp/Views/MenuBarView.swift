// MenuBarView.swift
// Premium menu bar popover WITHOUT SwiftUI property wrapper macros
// Uses manual state management via MenuBarViewModel

import SwiftUI
import Combine

// MARK: - MenuBarViewModel (NO @Published, NO @ObservableObject macro)

final class MenuBarViewModel {
    var showMainWindow = false { didSet { objectWillChange.send() } }
    var selectedLimit: Int = 80 { didSet { objectWillChange.send() } }
    var isApplying: Bool = false { didSet { objectWillChange.send() } }
    var authError: String? = nil { didSet { objectWillChange.send() } }
    var showingAuthAlert: Bool = false { didSet { objectWillChange.send() } }
    
    let objectWillChange = ObservableObjectPublisher()
    
    let service: ChargeLimitService
    let menuBarManager: MenuBarManager
    let onOpenSettings: () -> Void
    
    // Battery animation states
    let batteryState = BatteryViewState()
    let limitIndicatorState = BatteryViewState()
    
    // Shared component states (from SharedComponents)
    let sliderDragState = SliderDragState()
    let presetPressState = PressState()
    
    init(service: ChargeLimitService, menuBarManager: MenuBarManager, onOpenSettings: @escaping () -> Void) {
        self.service = service
        self.menuBarManager = menuBarManager
        self.onOpenSettings = onOpenSettings
        
        // Observe service changes
        service.onStateChange = { [weak self] _ in
            Task { @MainActor in
                self?.updateFromService()
            }
        }
    }
    
    private func updateFromService() {
        selectedLimit = currentLimit
        
        let charge = currentChargeLevel
        let charging = isCharging
        let limited = isLimitEnabled
        let limit = currentLimit
        
        batteryState.configure(
            chargeLevel: charge,
            isCharging: charging,
            isLimited: limited,
            limitPercent: limited ? limit : nil,
            size: .small,
            animated: true
        )
        
        limitIndicatorState.configure(
            chargeLevel: charge,
            isCharging: charging,
            isLimited: limited,
            limitPercent: limited ? limit : nil,
            size: .small,
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
    
    var timeRemaining: String {
        let status = service.state?.batteryStatus ?? ""
        if let range = status.range(of: #"(\d+:\d+)"#) {
            return String(status[range])
        }
        return isCharging ? "Расчёт..." : "—"
    }
    
    var isLoading: Bool {
        service.isLoading
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
        guard selectedLimit >= 20 && selectedLimit <= 100 else { return }
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
        onOpenSettings()
    }
}

// MARK: - MenuBarView (NO @StateObject, NO @State, NO @ObservedObject)

struct MenuBarView: View {
    let viewModel: MenuBarViewModel
    
    init(service: ChargeLimitService, menuBarManager: MenuBarManager, onOpenSettings: @escaping () -> Void) {
        self.viewModel = MenuBarViewModel(
            service: service,
            menuBarManager: menuBarManager,
            onOpenSettings: onOpenSettings
        )
    }
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
            
            VStack(spacing: 0) {
                // Header
                MenuBarHeaderSection(
                    isCharging: viewModel.isCharging,
                    chargeLevel: viewModel.currentChargeLevel,
                    isLoading: viewModel.isLoading
                )
                
                Divider().opacity(0.3)
                
                ScrollView {
                    VStack(spacing: 16) {
                        // Battery + Status
                        VStack(spacing: 14) {
                            BatteryView(
                                chargeLevel: viewModel.currentChargeLevel,
                                isCharging: viewModel.isCharging,
                                isLimited: viewModel.isLimitEnabled,
                                limitPercent: viewModel.isLimitEnabled ? viewModel.currentLimit : nil,
                                size: .tiny,
                                animated: true,
                                state: viewModel.batteryState
                            )
                            
                            HStack(spacing: 10) {
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
                                    text: viewModel.timeRemaining,
                                    icon: "clock.fill",
                                    color: .purple
                                )
                            }
                        }
                        
                        // Limit Control
                        LimitControlSection(viewModel: viewModel)
                        
                        // Quick Presets
                        QuickPresetsSection(viewModel: viewModel)
                        
                        // Action Buttons
                        ActionButtonsSection(viewModel: viewModel)
                    }
                    .padding(16)
                }
                
                Divider().opacity(0.3)
                
                // Footer
                HStack(spacing: 12) {
                    Button("Открыть") {
                        viewModel.showMainWindow = true
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    Button("Выход") {
                        NSApp.terminate(nil)
                    }
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.red.opacity(0.8))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .frame(width: 340)
        .onAppear {
            viewModel.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshChargeLimit)) { _ in
            viewModel.refresh()
        }
        .sheet(isPresented: Binding(
            get: { viewModel.showMainWindow },
            set: { viewModel.showMainWindow = $0 }
        )) {
            ContentView(service: viewModel.service, menuBarManager: viewModel.menuBarManager)
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

// MARK: - Limit Control Section

struct LimitControlSection: View {
    let viewModel: MenuBarViewModel
    
    var body: some View {
        VStack(spacing: 12) {
            // Toggle row
            PremiumToggleRow(
                icon: "slider.horizontal.3",
                title: "Лимит заряда",
                subtitle: "Остановить зарядку на заданном проценте",
                isOn: viewModel.isLimitEnabled,
                color: .blue,
                onToggle: { viewModel.toggleLimit($0) }
            )
            
            // Slider (when enabled)
            if viewModel.isLimitEnabled {
                VStack(spacing: 10) {
                    HStack {
                        Text("Максимальный заряд")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(viewModel.selectedLimit)%")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.blue)
                            .contentTransition(.numericText())
                    }
                    
                    CompactPremiumSlider(
                        value: Double(viewModel.selectedLimit),
                        range: 20...100,
                        step: 5,
                        activeColor: .blue,
                        trackColor: Color.blue.opacity(0.15),
                        onChange: { viewModel.setLimit(Int($0)) },
                        dragState: viewModel.sliderDragState
                    )
                    .frame(height: 36)
                }
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.blue.opacity(0.15), lineWidth: 1)
                )
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.95).combined(with: .opacity).combined(with: .offset(y: -8)),
                    removal: .scale(scale: 0.95).combined(with: .opacity).combined(with: .offset(y: -8))
                ))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: viewModel.isLimitEnabled)
    }
}

// MARK: - Quick Presets Section

struct QuickPresetsSection: View {
    let viewModel: MenuBarViewModel
    
    let presets = [20, 30, 40, 50, 60, 70, 80, 90, 100]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Быстрые пресеты")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(presets, id: \.self) { preset in
                        CompactPresetButton(
                            value: preset,
                            isSelected: viewModel.isLimitEnabled && viewModel.currentLimit == preset,
                            isEnabled: viewModel.isLimitEnabled,
                            action: { viewModel.setLimit(preset) },
                            pressState: viewModel.presetPressState
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Action Buttons Section

struct ActionButtonsSection: View {
    let viewModel: MenuBarViewModel
    
    var body: some View {
        VStack(spacing: 10) {
            Button(action: viewModel.applyLimit) {
                HStack(spacing: 8) {
                    if viewModel.isApplying {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .medium))
                    }
                    Text(viewModel.isApplying ? "Применение..." : "Применить \(viewModel.selectedLimit)%")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(PremiumButtonStyle(color: .blue))
            .disabled(viewModel.isApplying || viewModel.selectedLimit < 20 || viewModel.selectedLimit > 100 || (!viewModel.isLimitEnabled && viewModel.selectedLimit == 100))
            
            if viewModel.isLimitEnabled {
                Button(action: viewModel.disableLimit) {
                    HStack(spacing: 8) {
                        Image(systemName: "battery.100")
                            .font(.system(size: 13, weight: .medium))
                        Text("Отключить лимит")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(PremiumButtonStyle(color: .secondary))
                .disabled(viewModel.isApplying)
            }
            
            HStack(spacing: 10) {
                Button(action: viewModel.openSettings) {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 13, weight: .medium))
                        Text("Настройки")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(PremiumButtonStyle(color: .secondary))
                
                Button(action: viewModel.refresh) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                            .rotationEffect(.degrees(viewModel.isLoading ? 360 : 0))
                            .animation(
                                viewModel.isLoading ?
                                .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                                value: viewModel.isLoading
                            )
                        Text("Обновить")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(PremiumButtonStyle(color: .secondary))
                .disabled(viewModel.isLoading)
            }
        }
    }
}