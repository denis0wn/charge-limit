// SharedComponents.swift
// Reusable UI components WITHOUT SwiftUI property wrapper macros
// All components use manual state management via external bindings/parameters

import SwiftUI

// MARK: - Slider State (manual, no @State)

final class SliderDragState {
    var isDragging = false { didSet { onChange?() } }
    var onChange: (() -> Void)?
    
    init() {}
}

// MARK: - Premium Slider (Stateless, uses SliderDragState)

struct PremiumSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let activeColor: Color
    let trackColor: Color
    let onChange: (Double) -> Void
    let onDragStart: (() -> Void)?
    let onDragEnd: (() -> Void)?
    let dragState: SliderDragState
    
    init(
        value: Double,
        range: ClosedRange<Double>,
        step: Double,
        activeColor: Color,
        trackColor: Color,
        onChange: @escaping (Double) -> Void,
        onDragStart: (() -> Void)? = nil,
        onDragEnd: (() -> Void)? = nil,
        dragState: SliderDragState = SliderDragState()
    ) {
        self.value = value
        self.range = range
        self.step = step
        self.activeColor = activeColor
        self.trackColor = trackColor
        self.onChange = onChange
        self.onDragStart = onDragStart
        self.onDragEnd = onDragEnd
        self.dragState = dragState
    }
    
    var body: some View {
        GeometryReader { geo in
            let trackHeight: CGFloat = 6
            let thumbSize: CGFloat = 28
            let trackRect = CGRect(
                x: thumbSize / 2,
                y: (geo.size.height - trackHeight) / 2,
                width: geo.size.width - thumbSize,
                height: trackHeight
            )
            let progress = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let thumbX = trackRect.minX + trackRect.width * progress
            
            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(trackColor)
                    .frame(height: trackHeight)
                
                // Active track
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(
                        LinearGradient(
                            colors: [activeColor.opacity(0.8), activeColor],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: trackRect.width * progress, height: trackHeight)
                
                // Step marks
                ForEach(Array(stride(from: range.lowerBound, through: range.upperBound, by: step)), id: \.self) { stepValue in
                    let stepProgress = (stepValue - range.lowerBound) / (range.upperBound - range.lowerBound)
                    let stepX = trackRect.minX + trackRect.width * stepProgress
                    
                    Circle()
                        .fill(stepValue == value ? activeColor : Color.primary.opacity(0.15))
                        .frame(width: stepValue == value ? 10 : 5, height: stepValue == value ? 10 : 5)
                        .position(x: stepX, y: trackRect.midY)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: value)
                }
                
                // Thumb
                ZStack {
                    Circle()
                        .fill(.black.opacity(0.15))
                        .frame(width: thumbSize + 4, height: thumbSize + 4)
                        .blur(radius: 4)
                        .offset(y: 3)
                    
                    Circle()
                        .fill(.white)
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                        .overlay(
                            Circle()
                                .stroke(activeColor.opacity(0.3), lineWidth: 2)
                                .padding(2)
                        )
                        .overlay(
                            Circle()
                                .fill(activeColor)
                                .frame(width: 10, height: 10)
                        )
                }
                .position(x: thumbX, y: geo.size.height / 2)
                .scaleEffect(dragState.isDragging ? 1.2 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: dragState.isDragging)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !dragState.isDragging {
                            dragState.isDragging = true
                            onDragStart?()
                        }
                        let clampedX = min(max(gesture.location.x, trackRect.minX), trackRect.maxX)
                        let newProgress = (clampedX - trackRect.minX) / trackRect.width
                        let newValue = range.lowerBound + newProgress * (range.upperBound - range.lowerBound)
                        let steppedValue = round(newValue / step) * step
                        let clampedValue = min(max(steppedValue, range.lowerBound), range.upperBound)
                        onChange(clampedValue)
                    }
                    .onEnded { _ in
                        dragState.isDragging = false
                        onDragEnd?()
                    }
            )
        }
    }
}

// MARK: - Compact Premium Slider (for menu bar)

struct CompactPremiumSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let activeColor: Color
    let trackColor: Color
    let onChange: (Double) -> Void
    let dragState: SliderDragState
    
    init(
        value: Double,
        range: ClosedRange<Double>,
        step: Double,
        activeColor: Color,
        trackColor: Color,
        onChange: @escaping (Double) -> Void,
        dragState: SliderDragState = SliderDragState()
    ) {
        self.value = value
        self.range = range
        self.step = step
        self.activeColor = activeColor
        self.trackColor = trackColor
        self.onChange = onChange
        self.dragState = dragState
    }
    
    var body: some View {
        GeometryReader { geo in
            let trackHeight: CGFloat = 5
            let thumbSize: CGFloat = 24
            let trackRect = CGRect(
                x: thumbSize / 2,
                y: (geo.size.height - trackHeight) / 2,
                width: geo.size.width - thumbSize,
                height: trackHeight
            )
            let progress = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let thumbX = trackRect.minX + trackRect.width * progress
            
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(trackColor)
                    .frame(height: trackHeight)
                
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(
                        LinearGradient(
                            colors: [activeColor.opacity(0.8), activeColor],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: trackRect.width * progress, height: trackHeight)
                
                ForEach(Array(stride(from: range.lowerBound, through: range.upperBound, by: step)), id: \.self) { stepValue in
                    let stepProgress = (stepValue - range.lowerBound) / (range.upperBound - range.lowerBound)
                    let stepX = trackRect.minX + trackRect.width * stepProgress
                    
                    Circle()
                        .fill(stepValue == value ? activeColor : Color.primary.opacity(0.15))
                        .frame(width: stepValue == value ? 8 : 4, height: stepValue == value ? 8 : 4)
                        .position(x: stepX, y: trackRect.midY)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: value)
                }
                
                ZStack {
                    Circle()
                        .fill(.black.opacity(0.12))
                        .frame(width: thumbSize + 3, height: thumbSize + 3)
                        .blur(radius: 3)
                        .offset(y: 2)
                    
                    Circle()
                        .fill(.white)
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                        .overlay(
                            Circle()
                                .stroke(activeColor.opacity(0.3), lineWidth: 2)
                                .padding(2)
                        )
                        .overlay(
                            Circle()
                                .fill(activeColor)
                                .frame(width: 8, height: 8)
                        )
                }
                .position(x: thumbX, y: geo.size.height / 2)
                .scaleEffect(dragState.isDragging ? 1.15 : 1.0)
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: dragState.isDragging)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        dragState.isDragging = true
                        let clampedX = min(max(gesture.location.x, trackRect.minX), trackRect.maxX)
                        let newProgress = (clampedX - trackRect.minX) / trackRect.width
                        let newValue = range.lowerBound + newProgress * (range.upperBound - range.lowerBound)
                        let steppedValue = round(newValue / step) * step
                        onChange(min(max(steppedValue, range.lowerBound), range.upperBound))
                    }
                    .onEnded { _ in
                        dragState.isDragging = false
                    }
            )
        }
    }
}

// MARK: - Premium Toggle Style

struct PremiumToggleStyle: ToggleStyle {
    let color: Color
    let size: CGFloat
    
    init(color: Color = .blue, size: CGFloat = 32) {
        self.color = color
        self.size = size
    }
    
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            
            ZStack {
                RoundedRectangle(cornerRadius: size / 2)
                    .fill(configuration.isOn ? color : Color.primary.opacity(0.1))
                    .frame(width: size * 1.75, height: size)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isOn)
                    .overlay(
                        RoundedRectangle(cornerRadius: size / 2)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                
                Circle()
                    .fill(.white)
                    .frame(width: size - 6, height: size - 6)
                    .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 1)
                    .offset(x: configuration.isOn ? (size * 0.875 - (size - 6) / 2) : -(size * 0.875 - (size - 6) / 2))
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isOn)
            }
            .frame(width: size * 1.75, height: size)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    configuration.isOn.toggle()
                }
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
            }
        }
    }
}

// MARK: - Premium Toggle Row (with labels, stateless)

struct PremiumToggleRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let isOn: Bool
    let color: Color
    let isEnabled: Bool
    let onToggle: (Bool) -> Void
    
    init(
        icon: String,
        title: String,
        subtitle: String,
        isOn: Bool,
        color: Color,
        isEnabled: Bool = true,
        onToggle: @escaping (Bool) -> Void
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.isOn = isOn
        self.color = color
        self.isEnabled = isEnabled
        self.onToggle = onToggle
    }
    
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(isEnabled ? color.opacity(0.15) : Color.primary.opacity(0.06))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isEnabled ? color : Color.secondary.opacity(0.5))
            }
            
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.5))
                Text(subtitle)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(isOn ? color : Color.primary.opacity(0.1))
                    .frame(width: 56, height: 32)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isOn)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                
                Circle()
                    .fill(.white)
                    .frame(width: 26, height: 26)
                    .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 1)
                    .shadow(color: .black.opacity(0.05), radius: 1, x: 0, y: -1)
                    .offset(x: isOn ? 12 : -12)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isOn)
            }
            .frame(width: 56, height: 32)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
            .onTapGesture {
                guard isEnabled else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    onToggle(!isOn)
                }
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
            }
        }
        .opacity(isEnabled ? 1 : 0.6)
    }
}

// MARK: - Press State (for buttons)

final class PressState {
    var isPressed = false { didSet { onChange?() } }
    var onChange: (() -> Void)?
    
    init() {}
}

// MARK: - Preset Button (stateless, uses PressState)

struct PresetButton: View {
    let value: Int
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void
    let pressState: PressState
    
    init(
        value: Int,
        isSelected: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void,
        pressState: PressState = PressState()
    ) {
        self.value = value
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.action = action
        self.pressState = pressState
    }
    
    var body: some View {
        Button(action: {
            guard isEnabled else { return }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                pressState.isPressed = true
            }
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    pressState.isPressed = false
                }
            }
        }) {
            Text("\(value)%")
                .font(.system(size: 14, weight: isSelected ? .bold : .semibold, design: .rounded))
                .foregroundStyle(
                    isSelected ? .white : (isEnabled ? .primary : .secondary.opacity(0.5))
                )
                .frame(width: 52, height: 36)
                .background(
                    Group {
                        if isSelected {
                            LinearGradient(
                                colors: [.blue, .blue.opacity(0.8)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        } else {
                            Color(NSColor.controlBackgroundColor)
                        }
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            isSelected ? .clear : Color.primary.opacity(isEnabled ? 0.1 : 0.05),
                            lineWidth: 1
                        )
                )
                .shadow(
                    color: isSelected ? .blue.opacity(0.3) : .black.opacity(0.05),
                    radius: isSelected ? 8 : 2,
                    x: 0, y: isSelected ? 4 : 1
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(pressState.isPressed ? 0.92 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: pressState.isPressed)
        .disabled(!isEnabled)
    }
}

// MARK: - Compact Preset Button (for menu bar)

struct CompactPresetButton: View {
    let value: Int
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void
    let pressState: PressState
    
    init(
        value: Int,
        isSelected: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void,
        pressState: PressState = PressState()
    ) {
        self.value = value
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.action = action
        self.pressState = pressState
    }
    
    var body: some View {
        Button(action: {
            guard isEnabled else { return }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                pressState.isPressed = true
            }
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    pressState.isPressed = false
                }
            }
        }) {
            Text("\(value)%")
                .font(.system(size: 12, weight: isSelected ? .bold : .semibold, design: .rounded))
                .foregroundStyle(
                    isSelected ? .white : (isEnabled ? .primary : .secondary.opacity(0.5))
                )
                .frame(width: 46, height: 32)
                .background(
                    Group {
                        if isSelected {
                            LinearGradient(
                                colors: [.blue, .blue.opacity(0.8)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        } else {
                            Color(NSColor.controlBackgroundColor)
                        }
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isSelected ? .clear : Color.primary.opacity(isEnabled ? 0.1 : 0.05),
                            lineWidth: 1
                        )
                )
                .shadow(
                    color: isSelected ? .blue.opacity(0.3) : .black.opacity(0.05),
                    radius: isSelected ? 6 : 2,
                    x: 0, y: isSelected ? 3 : 1
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(pressState.isPressed ? 0.92 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: pressState.isPressed)
        .disabled(!isEnabled)
    }
}

// MARK: - Premium Button Style

struct PremiumButtonStyle: ButtonStyle {
    let color: Color
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(color == Color.secondary ? Color.primary : Color.white)
            .frame(maxWidth: .infinity)
            .background(
                Group {
                    if color == Color.secondary {
                        Color(NSColor.controlBackgroundColor)
                    } else {
                        LinearGradient(
                            colors: configuration.isPressed ?
                                [color.opacity(0.8), color.opacity(0.6)] :
                                [color, color.opacity(0.85)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        color == .secondary ? Color.primary.opacity(0.1) : .clear,
                        lineWidth: 1
                    )
            )
            .shadow(
                color: color == .secondary ? .black.opacity(0.05) : color.opacity(configuration.isPressed ? 0.2 : 0.35),
                radius: configuration.isPressed ? 4 : 8,
                x: 0, y: configuration.isPressed ? 2 : 4
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.15, dampingFraction: 0.8), value: configuration.isPressed)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Info Card

struct InfoCard: View {
    let icon: String
    let title: String
    let description: String
    let color: Color
    
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(color)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                
                Text(description)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
            
            Spacer(minLength: 0)
        }
    }
}

// MARK: - About Row

struct AboutRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.05), lineWidth: 0.5)
        )
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let icon: String
    let text: String
    let color: Color
    let isActive: Bool
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .rounded))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(
            Capsule().stroke(color.opacity(0.25), lineWidth: 0.5)
        )
        .opacity(isActive ? 1 : 0.5)
    }
}

// MARK: - Status Pill

struct StatusPill: View {
    let text: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(
            Capsule().stroke(color.opacity(0.3), lineWidth: 0.5)
        )
    }
}

// MARK: - Settings Section Container

struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(color)
                }
                
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            
            VStack(spacing: 0) {
                content
            }
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 4)
        }
    }
}

// MARK: - Settings Background

struct SettingsBackground: View {
    let phase: CGFloat
    
    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
            
            ForEach(0..<2, id: \.self) { i in
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.accentColor.opacity(0.06),
                                Color.accentColor.opacity(0.01),
                                .clear
                            ],
                            center: .center, startRadius: 0, endRadius: 180
                        )
                    )
                    .frame(width: 360, height: 360)
                    .blur(radius: 60)
                    .offset(
                        x: cos(phase + CGFloat(i) * 3.1) * 120,
                        y: sin(phase + CGFloat(i) * 2.3) * 80
                    )
                    .animation(.linear(duration: 35).repeatForever(autoreverses: false), value: phase)
            }
        }
    }
    
}

// MARK: - Settings Header

struct SettingsHeader: View {
    var body: some View {
        HStack(spacing: 16) {
            // App icon
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.blue, .blue.opacity(0.7), .purple],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 56, height: 56)
                    .shadow(color: .blue.opacity(0.3), radius: 15, x: 0, y: 8)
                
                Image(systemName: "battery.100.bolt")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("ChargeLimit")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("Настройки управления зарядом батареи")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding(.bottom, 8)
    }
}

// MARK: - Animated Background (for main window)

struct AnimatedBackground: View {
    let phase: CGFloat
    
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(NSColor.windowBackgroundColor),
                    Color(NSColor.controlBackgroundColor).opacity(0.5)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.accentColor.opacity(0.08),
                                Color.accentColor.opacity(0.02),
                                .clear
                            ],
                            center: .center, startRadius: 0, endRadius: 200
                        )
                    )
                    .frame(width: 400, height: 400)
                    .blur(radius: 80)
                    .offset(
                        x: cos(phase + CGFloat(i) * 2.1) * 150,
                        y: sin(phase + CGFloat(i) * 1.7) * 100
                    )
                    .animation(.linear(duration: 30).repeatForever(autoreverses: false), value: phase)
            }
            
            GridPattern()
                .opacity(0.02)
        }
    }
}

struct GridPattern: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 40
            let rows = Int(size.height / spacing) + 1
            let cols = Int(size.width / spacing) + 1
            
            for row in 0..<rows {
                for col in 0..<cols {
                    let x = CGFloat(col) * spacing
                    let y = CGFloat(row) * spacing
                    let rect = CGRect(x: x, y: y, width: 0.5, height: 0.5)
                    context.fill(Path(rect), with: .color(.primary.opacity(0.1)))
                }
            }
        }
    }
}

// MARK: - Top Bar

struct TopBarView: View {
    let onSettings: () -> Void
    let onQuit: () -> Void
    
    var body: some View {
        HStack {
            Text("ChargeLimit")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Настройки")
            
            Button(action: onQuit) {
                Image(systemName: "power")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Выйти")
        }
    }
}

// MARK: - Footer Section (Menu Bar)

struct MenuBarFooterSection: View {
    let onOpenApp: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Button("Открыть приложение") {
                onOpenApp()
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

// MARK: - Interval Picker (stateless segmented picker)

struct IntervalPicker: View {
    let selection: Int
    let options: [(Int, String)]
    let onChange: (Int) -> Void
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let (value, label) = option
                let isSelected = selection == value
                
                Button(action: { onChange(value) }) {
                    Text(label)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium, design: .rounded))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            ZStack {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(
                                            LinearGradient(
                                                colors: [.purple, .purple.opacity(0.8)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing
                                            )
                                        )
                                        .shadow(color: .purple.opacity(0.3), radius: 4, x: 0, y: 2)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelected)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
            }
            
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Divider Line

struct DividerLine: View {
    var body: some View {
        Divider().opacity(0.3)
    }
}

// MARK: - Animated Value (for number animations)

struct AnimatedValue: View {
    let value: Double
    let format: String
    let font: Font
    let color: Color
    
    var body: some View {
        Text(String(format: format, value))
            .font(font)
            .foregroundStyle(color)
            .contentTransition(.numericText())
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: value)
    }
}

// MARK: - ContentView Specific Components

// Quick Presets Section for ContentView
struct ContentQuickPresetsSection: View {
    let viewModel: ContentViewModel
    let presets = [20, 30, 40, 50, 60, 70, 80, 90, 100]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Быстрые пресеты")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(presets, id: \.self) { preset in
                        PresetButton(
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

// Action Buttons Section for ContentView
struct ContentActionButtonsSection: View {
    let viewModel: ContentViewModel
    
    var body: some View {
        VStack(spacing: 12) {
            Button(action: viewModel.applyLimit) {
                HStack(spacing: 10) {
                    if viewModel.isApplying {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .medium))
                    }
                    Text(viewModel.isApplying ? "Применение..." : "Применить \(viewModel.selectedLimit)%")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(PremiumButtonStyle(color: .blue))
            .disabled(viewModel.isApplying || !viewModel.isValidLimit(viewModel.selectedLimit) || (!viewModel.isLimitEnabled && viewModel.selectedLimit == 100))
            
            if viewModel.isLimitEnabled {
                Button(action: viewModel.disableLimit) {
                    HStack(spacing: 10) {
                        Image(systemName: "battery.100")
                            .font(.system(size: 15, weight: .medium))
                        Text("Отключить лимит (заряжать до 100%)")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(PremiumButtonStyle(color: .secondary))
                .disabled(viewModel.isApplying)
            }
            
            Button(action: viewModel.refresh) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .medium))
                        .rotationEffect(.degrees(viewModel.service.isLoading ? 360 : 0))
                        .animation(
                            viewModel.service.isLoading ?
                            .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                            value: viewModel.service.isLoading
                        )
                    Text("Обновить статус")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(PremiumButtonStyle(color: .secondary))
            .disabled(viewModel.service.isLoading)
        }
    }
}