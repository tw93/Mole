//
//  DesignAnimations.swift
//  Tonic
//
//  Animation modifiers and effects
//

import SwiftUI

// MARK: - Shimmer Effect

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    var gradientColors: [Color] = [
        Color.white.opacity(0),
        Color.white.opacity(0.3),
        Color.white.opacity(0)
    ]

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geometry in
                    LinearGradient(
                        colors: gradientColors,
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geometry.size.width)
                    .offset(x: -geometry.size.width + (phase * geometry.size.width * 2))
                }
            )
            .onAppear {
                withAnimation(
                    Animation.linear(duration: 1.5)
                        .repeatForever(autoreverses: false)
                ) {
                    phase = 1
                }
            }
    }
}

extension View {
    /// Apply shimmer loading effect
    func shimmer() -> some View {
        self.modifier(ShimmerModifier())
    }

    /// Apply shimmer with custom colors
    func shimmer(colors: [Color]) -> some View {
        self.modifier(ShimmerModifier(gradientColors: colors))
    }
}

// MARK: - Fade In Animation

struct FadeInModifier: ViewModifier {
    @State private var opacity: Double = 0
    let delay: TimeInterval

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .onAppear {
                withAnimation(
                    DesignTokens.AnimationCurve.smooth
                        .delay(delay)
                ) {
                    opacity = 1
                }
            }
    }
}

extension View {
    /// Fade in on appear with optional delay
    func fadeIn(delay: TimeInterval = 0) -> some View {
        self.modifier(FadeInModifier(delay: delay))
    }

    /// Fade in with slide from bottom
    func fadeInSlideUp(offset: CGFloat = 20, delay: TimeInterval = 0) -> some View {
        self.modifier(FadeInSlideUpModifier(offset: offset, delay: delay))
    }
}

struct FadeInSlideUpModifier: ViewModifier {
    @State private var opacity: Double = 0
    @State private var offset: CGFloat
    let delay: TimeInterval

    init(offset: CGFloat = 20, delay: TimeInterval = 0) {
        self._offset = State(initialValue: offset)
        self.delay = delay
    }

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .offset(y: offset)
            .onAppear {
                withAnimation(
                    DesignTokens.AnimationCurve.smooth
                        .delay(delay)
                ) {
                    opacity = 1
                    offset = 0
                }
            }
    }
}

// MARK: - Scale Animation

struct ScaleModifier: ViewModifier {
    @State private var scale: CGFloat = 0.9
    let delay: TimeInterval

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onAppear {
                withAnimation(
                    DesignTokens.AnimationCurve.spring
                        .delay(delay)
                ) {
                    scale = 1.0
                }
            }
    }
}

extension View {
    /// Scale in on appear with spring animation
    func scaleIn(delay: TimeInterval = 0) -> some View {
        self.modifier(ScaleModifier(delay: delay))
    }
}

// MARK: - Slide Animation

enum SlideDirection {
    case leading, trailing, top, bottom
}

struct SlideModifier: ViewModifier {
    @State private var offset: CGFloat
    let direction: SlideDirection
    let delay: TimeInterval

    init(direction: SlideDirection = .trailing, offset: CGFloat = 20, delay: TimeInterval = 0) {
        self._offset = State(initialValue: offset)
        self.direction = direction
        self.delay = delay
    }

    func body(content: Content) -> some View {
        content
            .offset(offsetForDirection)
            .onAppear {
                withAnimation(
                    DesignTokens.AnimationCurve.smooth
                        .delay(delay)
                ) {
                    offset = 0
                }
            }
    }

    private var offsetForDirection: CGSize {
        switch direction {
        case .leading: return CGSize(width: offset, height: 0)
        case .trailing: return CGSize(width: offset, height: 0)
        case .top: return CGSize(width: 0, height: -offset)
        case .bottom: return CGSize(width: 0, height: offset)
        }
    }
}

extension View {
    /// Slide in from specified direction
    func slideIn(from direction: SlideDirection = .trailing, offset: CGFloat = 20, delay: TimeInterval = 0) -> some View {
        self.modifier(SlideModifier(direction: direction, offset: offset, delay: delay))
    }
}

// MARK: - Bounce Effect

struct BounceModifier: ViewModifier {
    @State private var isBouncing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isBouncing ? 1.05 : 1.0)
            .animation(
                DesignTokens.AnimationCurve.springBouncy,
                value: isBouncing
            )
            .onAppear {
                isBouncing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    isBouncing = false
                }
            }
    }
}

extension View {
    /// Apply bounce effect on appear
    func bounce() -> some View {
        self.modifier(BounceModifier())
    }

    /// Apply bounce on tap gesture
    func bounceOnTap() -> some View {
        self.highPriorityGesture(
            TapGesture()
                .onEnded { _ in
                    // Bounce handled by modifier state
                }
        )
    }
}

// MARK: - Pulse Effect

struct PulseModifier: ViewModifier {
    @State private var isPulsing = false
    let intensity: Double

    init(intensity: Double = 0.3) {
        self.intensity = intensity
    }

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 1.0 : 1.0 - intensity)
            .scaleEffect(isPulsing ? 1.02 : 1.0)
            .animation(
                Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear {
                isPulsing = true
            }
    }
}

extension View {
    /// Apply continuous pulse animation
    func pulse(intensity: Double = 0.3) -> some View {
        self.modifier(PulseModifier(intensity: intensity))
    }
}

// MARK: - Rotation Effect

struct RotationModifier: ViewModifier {
    @State private var isRotating = false
    let duration: Double
    let degrees: Double

    init(duration: Double = 2, degrees: Double = 360) {
        self.duration = duration
        self.degrees = degrees
    }

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(isRotating ? degrees : 0))
            .onAppear {
                withAnimation(
                    Animation.linear(duration: duration)
                        .repeatForever(autoreverses: false)
                ) {
                    isRotating = true
                }
            }
    }
}

extension View {
    /// Apply continuous rotation animation
    func rotate(duration: Double = 2, degrees: Double = 360) -> some View {
        self.modifier(RotationModifier(duration: duration, degrees: degrees))
    }
}

// MARK: - Press Effect

struct PressEffectModifier: ViewModifier {
    @State private var isPressed = false
    let scale: CGFloat

    init(scale: CGFloat = 0.95) {
        self.scale = scale
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? scale : 1.0)
            .animation(DesignTokens.Animation.fast, value: isPressed)
            .onTapGesture {
                withAnimation(DesignTokens.Animation.fast) {
                    isPressed = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isPressed = false
                }
            }
    }
}

extension View {
    /// Apply press scale effect
    func pressEffect(scale: CGFloat = 0.95) -> some View {
        self.modifier(PressEffectModifier(scale: scale))
    }
}

// MARK: - Interactive Animation

struct InteractivePressModifier: ViewModifier {
    @GestureState private var isPressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? 0.95 : 1.0)
            .animation(DesignTokens.Animation.fast, value: isPressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, state, _ in
                        state = true
                    }
            )
    }
}

extension View {
    /// Apply interactive press effect with gesture
    func interactivePress() -> some View {
        self.modifier(InteractivePressModifier())
    }
}

// MARK: - Skeleton Loading

struct SkeletonLoadingModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(DesignTokens.Colors.surfaceElevated)
            .shimmer()
            .cornerRadius(DesignTokens.CornerRadius.medium)
    }
}

extension View {
    /// Apply skeleton loading placeholder style
    func skeleton() -> some View {
        self.modifier(SkeletonLoadingModifier())
    }
}

// MARK: - Transition Extensions

extension AnyTransition {
    static var scaleAndFade: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.9).combined(with: .opacity),
            removal: .scale(scale: 0.9).combined(with: .opacity)
        )
    }

    static var slideAndFade: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }
}

// MARK: - Stagger Container (Simplified version without _VariadicView)

struct StaggerContainer<Content: View>: View {
    let staggerDelay: TimeInterval
    let content: Content

    init(staggerDelay: TimeInterval = 0.1, @ViewBuilder content: () -> Content) {
        self.staggerDelay = staggerDelay
        self.content = content()
    }

    var body: some View {
        content
    }
}

extension View {
    /// Apply stagger animation - placeholder for future implementation
    func stagger(delay: TimeInterval = 0.1) -> some View {
        StaggerContainer(staggerDelay: delay) {
            self
        }
    }
}

// MARK: - Conditional Animation

extension View {
    /// Apply animation based on condition
    func animateIf(_ condition: Bool, animation: SwiftUI.Animation = .default) -> some View {
        self.animation(condition ? animation : nil, value: condition)
    }
}
