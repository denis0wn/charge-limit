// SettingsView.swift
// Premium settings window WITHOUT SwiftUI property wrapper macros
// Uses manual state management via SettingsViewModel

import SwiftUI
import ServiceManagement
import Combine

// MARK: - SettingsViewModel (NO @Published, NO @ObservableObject macro)

final class SettingsViewModel {
    var launchAtLogin: Bool = false { didSet { objectWillChange.send() } }
    var showInMenuBar: Bool = true { didSet { objectWillChange.send() } }
    var showPercentageInMenuBar: Bool = true { didSet { objectWillChange.send() } }
    var notifyOnLimitReached: Bool = true { didSet { objectWillChange.send() } }
    var checkInterval: Int = 300 { didSet { objectWillChange.send() } }
    var backgroundPhase: CGFloat = 0 { didSet { objectWillChange.send() } }
    
    // Helper status
    var helperStatus: String = "Проверка..." { didSet { objectWillChange.send() } }
    var helperStatusColor: Color = .blue { didSet { objectWillChange.send() } }
    var helperNeedsAction: Bool = false { didSet { objectWillChange.send() } }
    var helperActionTitle: String = "" { didSet { objectWillChange.send() } }
    var helperError: String? = nil { didSet { objectWillChange.send() } }
    
    let objectWillChange = ObservableObjectPublisher()
    private let helperManager = HelperManager.shared
    
    init() {
        loadDefaults()
        updateHelperStatus()
    }
    
    private func loadDefaults() {
        let defaults = UserDefaults.standard
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        showInMenuBar = defaults.object(forKey: "showInMenuBar") as? Bool ?? true
        showPercentageInMenuBar = defaults.object(forKey: "showPercentageInMenuBar") as? Bool ?? true
        notifyOnLimitReached = defaults.object(forKey: "notifyOnLimitReached") as? Bool ?? true
        checkInterval = defaults.object(forKey: "checkInterval") as? Int ?? 300
    }
    
    func updateHelperStatus() {
        helperManager.refreshStatus()
        
        switch helperManager.status {
        case .enabled:
            helperStatus = "Привилегированный хелпер установлен и активен ✓"
            helperStatusColor = .green
            helperNeedsAction = false
        case .requiresApproval:
            helperStatus = "Требуется одобрение в Настройках системы ⚠️"
            helperStatusColor = .orange
            helperNeedsAction = true
            helperActionTitle = "Открыть Настройки системы"
        case .notRegistered:
            helperStatus = "Привилегированный хелпер не установлен"
            helperStatusColor = .blue
            helperNeedsAction = true
            helperActionTitle = "Установить хелпер"
        case .notFound:
            helperStatus = "Конфигурация хелпера не найдена в приложении"
            helperStatusColor = .red
            helperNeedsAction = false
        @unknown default:
            helperStatus = "Статус неизвестен"
            helperStatusColor = .gray
            helperNeedsAction = false
        }
        
        helperError = helperManager.lastError
    }
    
    func registerHelper() {
        Task {
            do {
                try await helperManager.register()
                await MainActor.run { self.updateHelperStatus() }
            } catch {
                await MainActor.run {
                    self.helperError = error.localizedDescription
                    self.updateHelperStatus()
                }
            }
        }
    }
    
    func openSystemSettingsForHelper() {
        helperManager.openSystemSettings()
    }
    
    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled
        UserDefaults.standard.set(enabled, forKey: "launchAtLogin")
        
        #if os(macOS)
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to set launch at login: \(error)")
        }
        #endif
    }
    
    func setShowInMenuBar(_ enabled: Bool) {
        showInMenuBar = enabled
        UserDefaults.standard.set(enabled, forKey: "showInMenuBar")
    }
    
    func setShowPercentageInMenuBar(_ enabled: Bool) {
        showPercentageInMenuBar = enabled
        UserDefaults.standard.set(enabled, forKey: "showPercentageInMenuBar")
    }
    
    func setNotifyOnLimitReached(_ enabled: Bool) {
        notifyOnLimitReached = enabled
        UserDefaults.standard.set(enabled, forKey: "notifyOnLimitReached")
    }
    
    func setCheckInterval(_ interval: Int) {
        checkInterval = interval
        UserDefaults.standard.set(interval, forKey: "checkInterval")
    }
    
    func startBackgroundAnimation() {
        withAnimation(.linear(duration: 25).repeatForever(autoreverses: false)) {
            backgroundPhase = 2 * .pi
        }
    }
}

// MARK: - SettingsView (NO @StateObject, NO @State, NO @Binding)

struct SettingsView: View {
    let viewModel: SettingsViewModel
    
    init() {
        self.viewModel = SettingsViewModel()
    }
    
    var body: some View {
        ZStack {
            // Animated background
            SettingsBackground(phase: viewModel.backgroundPhase)
                .ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    SettingsHeader()
                    
                    // Helper Status Section
                    SettingsSection(title: "Привилегированный хелпер", icon: "shield.lefthalf.filled", color: .blue) {
                        VStack(spacing: 16) {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(viewModel.helperStatusColor.opacity(0.15))
                                        .frame(width: 36, height: 36)
                                    Image(systemName: helperStatusIcon)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(viewModel.helperStatusColor)
                                }
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Статус системного демона")
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.primary)
                                    Text(viewModel.helperStatus)
                                        .font(.system(size: 11, weight: .regular, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                                
                                Spacer()
                            }
                            
                            if viewModel.helperNeedsAction {
                                Button(action: viewModel.helperActionTitle == "Установить хелпер" ? viewModel.registerHelper : viewModel.openSystemSettingsForHelper) {
                                    HStack(spacing: 8) {
                                        Image(systemName: viewModel.helperActionTitle == "Установить хелпер" ? "arrow.down.circle.fill" : "gearshape.fill")
                                            .font(.system(size: 13, weight: .medium))
                                        Text(viewModel.helperActionTitle)
                                            .font(.system(size: 13, weight: .medium, design: .rounded))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                }
                                .buttonStyle(PremiumButtonStyle(color: viewModel.helperStatusColor))
                            }
                            
                            if let error = viewModel.helperError {
                                Text(error)
                                    .font(.system(size: 11, weight: .regular, design: .rounded))
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    
                    // General section
                    SettingsSection(title: "Общие", icon: "gearshape.fill", color: .blue) {
                        VStack(spacing: 16) {
                            PremiumToggleRow(
                                icon: "power.circle.fill",
                                title: "Запускать при входе в систему",
                                subtitle: "Автоматически стартовать при загрузке macOS",
                                isOn: viewModel.launchAtLogin,
                                color: .blue,
                                onToggle: { viewModel.setLaunchAtLogin($0) }
                            )
                            
                            PremiumToggleRow(
                                icon: "menubar.rectangle",
                                title: "Показывать в строке меню",
                                subtitle: "Иконка с процентом заряда в статус-баре",
                                isOn: viewModel.showInMenuBar,
                                color: .green,
                                onToggle: { viewModel.setShowInMenuBar($0) }
                            )
                            
                            if viewModel.showInMenuBar {
                                PremiumToggleRow(
                                    icon: "number.circle.fill",
                                    title: "Показывать процент в иконке",
                                    subtitle: "Отображать % заряда рядом с иконкой батареи",
                                    isOn: viewModel.showPercentageInMenuBar,
                                    color: .orange,
                                    isEnabled: viewModel.showInMenuBar,
                                    onToggle: { viewModel.setShowPercentageInMenuBar($0) }
                                )
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: viewModel.showInMenuBar)
                    }
                    
                    // Notifications section
                    SettingsSection(title: "Уведомления", icon: "bell.fill", color: .orange) {
                        VStack(spacing: 16) {
                            PremiumToggleRow(
                                icon: "bell.badge.fill",
                                title: "Уведомлять при достижении лимита",
                                subtitle: "Показывать системное уведомление, когда зарядка остановится",
                                isOn: viewModel.notifyOnLimitReached,
                                color: .orange,
                                onToggle: { viewModel.setNotifyOnLimitReached($0) }
                            )
                            
                            // Interval picker
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 12) {
                                    ZStack {
                                        Circle()
                                            .fill(Color.purple.opacity(0.15))
                                            .frame(width: 36, height: 36)
                                        Image(systemName: "clock.fill")
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(.purple)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Интервал проверки")
                                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.primary)
                                        Text("Как часто проверять состояние батареи")
                                            .font(.system(size: 11, weight: .regular, design: .rounded))
                                            .foregroundStyle(.secondary)
                                    }
                                    
                                    Spacer()
                                }
                                
                                IntervalPicker(
                                    selection: viewModel.checkInterval,
                                    options: [
                                        (60, "Каждую минуту"),
                                        (300, "Каждые 5 минут"),
                                        (900, "Каждые 15 минут"),
                                        (3600, "Каждый час")
                                    ],
                                    onChange: { viewModel.setCheckInterval($0) }
                                )
                                .padding(.leading, 48)
                            }
                        }
                    }
                    
                    // Advanced section
                    SettingsSection(title: "Дополнительно", icon: "wrench.and.screwdriver.fill", color: .purple) {
                        VStack(spacing: 18) {
                            InfoCard(
                                icon: "cpu.fill",
                                title: "Механизм работы",
                                description: "Приложение использует привилегированный XPC-хелпер (SMAppService daemon) для записи лимита заряда через системный домен com.apple.smartcharging.topoffprotection. Хелпер устанавливается в /Library/PrivilegedHelperTools/ и требует однократного одобрения в Настройках системы.",
                                color: .blue
                            )
                            
                            InfoCard(
                                icon: "exclamationmark.triangle.fill",
                                title: "Ограничения и нюансы",
                                description: """
                                    • Системный ползунок в «Настройках → Батарея» показывает только 80–100%
                                    • Это приложение позволяет установить 20–100% (гранулярность 5%)
                                    • Установка хелпера требует одобрения в Настройках системы (один раз)
                                    • Установленный лимит сохраняется после перезагрузки Mac
                                    • Обновление macOS может изменить ключи настроек — приложение обновится
                                    • Работает на Apple Silicon (M1/M2/M3/M4) и Intel
                                    """,
                                color: .orange
                            )
                            
                            // GitHub link
                            Link(destination: URL(string: "https://github.com/denis0wn/charge-limit")!) {
                                HStack(spacing: 10) {
                                    ZStack {
                                        Circle()
                                            .fill(Color.primary.opacity(0.1))
                                            .frame(width: 36, height: 36)
                                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundStyle(.primary)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Исходный код на GitHub")
                                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.primary)
                                        Text("denis0wn/charge-limit")
                                            .font(.system(size: 11, weight: .regular, design: .rounded))
                                            .foregroundStyle(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(16)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    // About section
                    SettingsSection(title: "О приложении", icon: "info.circle.fill", color: .gray) {
                        VStack(spacing: 12) {
                            AboutRow(label: "Версия", value: "1.0.0")
                            AboutRow(label: "Совместимость", value: "macOS 14.0+ (Sonoma)")
                            AboutRow(label: "Архитектура", value: "Apple Silicon / Intel")
                            AboutRow(label: "Режим сборки", value: "SPM (Swift Package Manager)")
                            AboutRow(label: "Подпись", value: "Ad-hoc (локальная разработка)")
                            AboutRow(label: "Привилегированный хелпер", value: "SMAppService daemon")
                        }
                    }
                    
                    Spacer(minLength: 20)
                }
                .padding(24)
            }
        }
        .frame(width: 520, height: 620)
        .onAppear {
            viewModel.startBackgroundAnimation()
            viewModel.updateHelperStatus()
        }
    }
    
    private var helperStatusIcon: String {
        let status = HelperManager.shared.status
        switch status {
        case .enabled: return "checkmark.shield.fill"
        case .requiresApproval: return "exclamationmark.triangle.fill"
        case .notRegistered: return "arrow.down.circle.fill"
        case .notFound: return "xmark.shield.fill"
        @unknown default: return "questionmark.shield.fill"
        }
    }
}