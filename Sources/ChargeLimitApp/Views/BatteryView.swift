// BatteryView.swift
// Premium animated battery component WITHOUT SwiftUI property wrapper macros
// Animation state managed by BatteryViewState class

import SwiftUI
import Combine

// MARK: - Battery Fill Shape with Rounded Corners

struct BatteryFillShape: Shape {
    let cornerRadius: CGFloat
    let fillRatio: CGFloat  // 0...1
    
    func path(in rect: CGRect) -> Path {
        let fillWidth = max(2, rect.width * fillRatio)
        let fillRect = CGRect(x: 0, y: 0, width: fillWidth, height: rect.height)
        return Path(roundedRect: fillRect, cornerRadius: cornerRadius)
    }
}

// MARK: - Battery Outline Shape

struct BatteryOutlineShape: Shape {
    let cornerRadius: CGFloat
    let tipWidth: CGFloat
    let tipHeight: CGFloat
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let bodyWidth = rect.width - tipWidth
        let tipX = bodyWidth
        let tipY = (rect.height - tipHeight) / 2
        
        // Main body
        path.addRoundedRect(
            in: CGRect(x: 0, y: 0, width: bodyWidth, height: rect.height),
            cornerSize: CGSize(width: cornerRadius, height: cornerRadius)
        )
        
        // Tip (positive terminal)
        let tipRect = CGRect(x: tipX, y: tipY, width: tipWidth, height: tipHeight)
        let tipRadius = min(tipWidth, tipHeight) / 2
        path.addRoundedRect(in: tipRect, cornerSize: CGSize(width: tipRadius, height: tipRadius))
        
        return path
    }
}

// MARK: - Gloss Overlay Shape

struct BatteryGlossShape: Shape {
    let cornerRadius: CGFloat
    
    func path(in rect: CGRect) -> Path {
        let glossHeight = rect.height * 0.45
        let glossRect = CGRect(x: 2, y: 2, width: rect.width - 4, height: glossHeight)
        return Path(roundedRect: glossRect, cornerRadius: cornerRadius - 2)
    }
}

// MARK: - Liquid Wave Animation

struct LiquidWave: View {
    let progress: CGFloat
    let color: Color
    let phase: CGFloat
    let amplitude: CGFloat
    let frequency: CGFloat = 1.5
    
    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let width = geo.size.width
            let baseY = height * (1 - progress)
            
            Path { path in
                path.move(to: CGPoint(x: 0, y: height))
                path.addLine(to: CGPoint(x: 0, y: baseY))
                
                var x: CGFloat = 0
                while x <= width {
                    let y = baseY + sin((x / width * frequency * 2 * .pi) + phase) * amplitude * (1 - progress)
                    path.addLine(to: CGPoint(x: x, y: y))
                    x += 2
                }
                
                path.addLine(to: CGPoint(x: width, y: height))
                path.closeSubpath()
            }
            .fill(color.opacity(0.6))
            
            // Second wave layer
            Path { path in
                path.move(to: CGPoint(x: 0, y: height))
                path.addLine(to: CGPoint(x: 0, y: baseY + 8))
                
                var x: CGFloat = 0
                while x <= width {
                    let y = baseY + 8 + sin((x / width * frequency * 2 * .pi) + phase + .pi * 0.7) * amplitude * 0.6 * (1 - progress)
                    path.addLine(to: CGPoint(x: x, y: y))
                    x += 2
                }
                
                path.addLine(to: CGPoint(x: width, y: height))
                path.closeSubpath()
            }
            .fill(color.opacity(0.35))
        }
    }
}

// MARK: - Battery Animation State (ObservableObject WITHOUT @Published macro)

final class BatteryViewState {
    var wavePhase: CGFloat = 0 { didSet { objectWillChange.send() } }
    var fillProgress: CGFloat = 0 { didSet { objectWillChange.send() } }
    var pulseScale: CGFloat = 1 { didSet { objectWillChange.send() } }
    var glossOpacity: Double = 0 { didSet { objectWillChange.send() } }
    var isAnimating: Bool = false { didSet { objectWillChange.send() } }
    
    let objectWillChange = ObservableObjectPublisher()
    
    private var animationCancellables = Set<AnyCancellable>()
    private var chargeLevel: Double = 0
    private var isCharging: Bool = false
    private var animated: Bool = false
    private var size: BatterySize = .medium
    
    enum BatterySize {
        case tiny      // Menu bar ~28px
        case small     // Popover ~60px
        case medium    // Main ~120px
        case large     // Hero ~200px
        case extraLarge // Settings ~280px
        
        var dimensions: (width: CGFloat, height: CGFloat, cornerRadius: CGFloat, tipWidth: CGFloat, tipHeight: CGFloat, fontSize: CGFloat, showPercent: Bool) {
            switch self {
            case .tiny:      return (44, 22, 4, 4, 10, 9, false)
            case .small:     return (80, 40, 6, 6, 16, 14, true)
            case .medium:    return (160, 80, 10, 10, 28, 28, true)
            case .large:     return (240, 120, 14, 14, 40, 42, true)
            case .extraLarge: return (320, 160, 18, 18, 52, 56, true)
            }
        }
        
        var waveAmplitude: CGFloat {
            switch self {
            case .tiny: return 1.5
            case .small: return 2.5
            case .medium: return 4
            case .large: return 6
            case .extraLarge: return 8
            }
        }
    }
    
    func configure(chargeLevel: Double, isCharging: Bool, isLimited: Bool, limitPercent: Int?, size: BatterySize, animated: Bool) {
        self.chargeLevel = chargeLevel
        self.isCharging = isCharging
        self.animated = animated
        self.size = size
        
        // Stop previous animations
        stopAnimations()
        
        // Set initial values
        let targetFill = CGFloat(chargeLevel / 100.0)
        fillProgress = targetFill
        glossOpacity = isCharging ? 0.8 : 0.4
        pulseScale = isCharging ? 1.02 : 1.0
        
        // Start animations if needed
        if animated || isCharging {
            startWaveAnimation()
        }
        if isCharging {
            startPulseAnimation()
        }
    }
    
    func updateChargeLevel(_ newValue: Double) {
        chargeLevel = newValue
        let targetFill = CGFloat(newValue / 100.0)
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
            fillProgress = targetFill
        }
    }
    
    func updateCharging(_ newValue: Bool) {
        isCharging = newValue
        pulseScale = newValue ? 1.02 : 1.0
        withAnimation(.easeInOut(duration: 0.3)) {
            glossOpacity = newValue ? 0.8 : 0.4
        }
        if newValue {
            startPulseAnimation()
        } else {
            stopPulseAnimation()
        }
    }
    
    func updateLimited(_ newValue: Bool) {
        // Trigger subtle animation when limit state changes
    }
    
    private func startAnimations() {
        if animated || isCharging {
            startWaveAnimation()
        }
        if isCharging {
            startPulseAnimation()
        }
    }
    
    private func startWaveAnimation() {
        guard !isAnimating else { return }
        isAnimating = true
        
        Timer.publish(every: 1/60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.wavePhase += 2 * .pi / (1.2 * 60)
                if self.wavePhase >= 2 * .pi {
                    self.wavePhase -= 2 * .pi
                }
            }
            .store(in: &animationCancellables)
    }
    
    private func startPulseAnimation() {
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
            pulseScale = 1.03
        }
    }
    
    private func stopAnimations() {
        animationCancellables.forEach { $0.cancel() }
        animationCancellables.removeAll()
        isAnimating = false
        stopPulseAnimation()
    }
    
    private func stopPulseAnimation() {
        withAnimation(.easeInOut(duration: 0.3)) {
            pulseScale = 1.0
        }
    }
    
    deinit {
        stopAnimations()
    }
    
    var dims: (width: CGFloat, height: CGFloat, cornerRadius: CGFloat, tipWidth: CGFloat, tipHeight: CGFloat, fontSize: CGFloat, showPercent: Bool) {
        size.dimensions
    }
    
    var targetFill: CGFloat {
        CGFloat(chargeLevel / 100.0)
    }
    
    var batteryColor: Color {
        if isCharging { return .green }
        if chargeLevel <= 20 { return .red }
        if chargeLevel <= 40 { return .orange }
        return .green
    }
    
    var limitColor: Color {
        .blue
    }
}

// MARK: - Main Battery View (NO @State, NO @ObservedObject)

struct BatteryView: View {
    let chargeLevel: Double        // 0...100
    let isCharging: Bool
    let isLimited: Bool
    let limitPercent: Int?
    let size: BatteryViewState.BatterySize
    let animated: Bool
    let state: BatteryViewState
    
    init(
        chargeLevel: Double,
        isCharging: Bool,
        isLimited: Bool,
        limitPercent: Int?,
        size: BatteryViewState.BatterySize,
        animated: Bool,
        state: BatteryViewState
    ) {
        self.chargeLevel = chargeLevel
        self.isCharging = isCharging
        self.isLimited = isLimited
        self.limitPercent = limitPercent
        self.size = size
        self.animated = animated
        self.state = state
        
        // Configure state
        state.configure(
            chargeLevel: chargeLevel,
            isCharging: isCharging,
            isLimited: isLimited,
            limitPercent: limitPercent,
            size: size,
            animated: animated
        )
    }
    
    var body: some View {
        ZStack {
            // Background shadow/glow
            if size != .tiny {
                BatteryOutlineShape(cornerRadius: state.dims.cornerRadius, tipWidth: state.dims.tipWidth, tipHeight: state.dims.tipHeight)
                    .fill(state.batteryColor.opacity(0.15))
                    .blur(radius: size == .large || size == .extraLarge ? 20 : 10)
                    .scaleEffect(state.pulseScale)
            }
            
            // Battery outline
            BatteryOutlineShape(cornerRadius: state.dims.cornerRadius, tipWidth: state.dims.tipWidth, tipHeight: state.dims.tipHeight)
                .stroke(
                    LinearGradient(
                        colors: [Color.primary.opacity(0.3), Color.primary.opacity(0.1)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: size == .tiny ? 1.5 : (size == .small ? 2 : 2.5)
                )
                .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
            
            // Fill with liquid animation
            ZStack {
                // Base fill
                BatteryFillShape(cornerRadius: state.dims.cornerRadius - 2, fillRatio: state.fillProgress)
                    .fill(
                        LinearGradient(
                            colors: [
                                state.batteryColor.opacity(0.9),
                                state.batteryColor.opacity(0.7),
                                state.batteryColor.opacity(0.85)
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                
                // Liquid waves when charging or animating
                if (isCharging || animated) && state.fillProgress > 0.02 {
                    LiquidWave(
                        progress: state.fillProgress,
                        color: state.batteryColor,
                        phase: state.wavePhase,
                        amplitude: size.waveAmplitude
                    )
                    .clipShape(BatteryFillShape(cornerRadius: state.dims.cornerRadius - 2, fillRatio: state.fillProgress))
                }
                
                // Gloss overlay
                BatteryGlossShape(cornerRadius: state.dims.cornerRadius)
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(state.glossOpacity * 0.4),
                                .white.opacity(state.glossOpacity * 0.05),
                                .clear
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .allowsHitTesting(false)
            }
            .clipShape(BatteryFillShape(cornerRadius: state.dims.cornerRadius - 2, fillRatio: 1))
            .padding(EdgeInsets(top: 2, leading: 2, bottom: 2, trailing: state.dims.tipWidth + 2))
            
            // Charge limit indicator line
            if let limit = limitPercent, isLimited, !isCharging {
                GeometryReader { geo in
                    let limitX = geo.size.width * (CGFloat(limit) / 100.0) - 1
                    Rectangle()
                        .fill(state.limitColor)
                        .frame(width: 2.5, height: geo.size.height - 4)
                        .position(x: limitX, y: geo.size.height / 2)
                        .shadow(color: state.limitColor, radius: 3)
                        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: limit)
                }
                .padding(EdgeInsets(top: 2, leading: 2, bottom: 2, trailing: state.dims.tipWidth + 2))
            }
            
            // Percentage text
            if state.dims.showPercent {
                Text("\(Int(chargeLevel))%")
                    .font(.system(size: state.dims.fontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(
                        state.fillProgress > 0.5 ? .white : .primary
                    )
                    .shadow(color: .black.opacity(state.fillProgress > 0.5 ? 0.3 : 0), radius: 1, x: 0, y: 1)
                    .animation(.easeOut(duration: 0.2), value: state.fillProgress)
                    .transition(.opacity.combined(with: .scale))
            }
            
            // Charging bolt overlay
            if isCharging && size != .tiny {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "bolt.fill")
                            .font(.system(size: state.dims.fontSize * 0.7, weight: .bold))
                            .foregroundStyle(.yellow)
                            .shadow(color: .yellow.opacity(0.8), radius: 4)
                            .symbolEffect(.bounce, options: .repeating, value: isCharging)
                            .padding(.trailing, state.dims.tipWidth + 8)
                            .padding(.top, 6)
                    }
                    Spacer()
                }
            }
        }
        .frame(width: state.dims.width, height: state.dims.height)
        .onChange(of: chargeLevel) { _, newValue in
            state.updateChargeLevel(newValue)
        }
        .onChange(of: isCharging) { _, newValue in
            state.updateCharging(newValue)
        }
        .onChange(of: isLimited) { _, newValue in
            state.updateLimited(newValue)
        }
    }
}

// MARK: - Compact Battery for Menu Bar

struct CompactBatteryView: View {
    let chargeLevel: Double
    let isCharging: Bool
    let isLimited: Bool
    let limitPercent: Int?
    let state: BatteryViewState
    
    var body: some View {
        BatteryView(
            chargeLevel: chargeLevel,
            isCharging: isCharging,
            isLimited: isLimited,
            limitPercent: limitPercent,
            size: .tiny,
            animated: false,
            state: state
        )
    }
}

// MARK: - Battery State Factory (creates shared state for each size)

struct BatteryStateProvider {
    static func makeState(for size: BatteryViewState.BatterySize) -> BatteryViewState {
        BatteryViewState()
    }
}