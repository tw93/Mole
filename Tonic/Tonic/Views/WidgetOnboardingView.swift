//
//  WidgetOnboardingView.swift
//  Tonic
//
//  Widget onboarding tour experience
//  Task ID: fn-2.14
//

import SwiftUI

/// Onboarding view for menu bar widgets
public struct WidgetOnboardingView: View {

    @AppStorage("hasCompletedWidgetOnboarding") private var hasCompletedOnboarding = false
    @State private var currentPage = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "square.grid.2x2",
            title: "Menu Bar Widgets",
            description: "Monitor your system at a glance with customizable widgets in the menu bar."
        ),
        OnboardingPage(
            icon: "cpu",
            title: "Real-Time Monitoring",
            description: "Track CPU, Memory, Disk, Network, and more with updates every 2 seconds."
        ),
        OnboardingPage(
            icon: "hand.tap.fill",
            title: "Fully Customizable",
            description: "Choose which widgets to show, their display mode, and arrange them in any order."
        ),
        OnboardingPage(
            icon: "bell.badge.fill",
            title: "Smart Notifications",
            description: "Get notified about important system events like high CPU usage or low disk space."
        )
    ]

    public init() {}

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Current page content
            TabView(selection: $currentPage) {
                ForEach(0..<pages.count, id: \.self) { index in
                    OnboardingPageView(page: pages[index])
                        .tag(index)
                }
            }
            .frame(height: 300)

            // Page indicators
            HStack(spacing: 8) {
                ForEach(0..<pages.count, id: \.self) { index in
                    Circle()
                        .fill(currentPage == index ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }

            Spacer()

            // Action buttons
            HStack(spacing: 16) {
                if currentPage > 0 {
                    Button("Back") {
                        withAnimation {
                            currentPage -= 1
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                Button(currentPage < pages.count - 1 ? "Next" : "Get Started") {
                    if currentPage < pages.count - 1 {
                        withAnimation {
                            currentPage += 1
                        }
                    } else {
                        completeOnboarding()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
            .padding()
        }
        .padding()
        .frame(width: 500, height: 500)
    }

    private func completeOnboarding() {
        hasCompletedOnboarding = true
        WidgetPreferences.shared.setHasCompletedOnboarding(true)

        // Start the widget coordinator
        WidgetCoordinator.shared.start()
    }
}

// MARK: - Onboarding Page Model

struct OnboardingPage {
    let icon: String
    let title: String
    let description: String
}

// MARK: - Onboarding Page View

struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 32) {
            Image(systemName: page.icon)
                .font(.system(size: 64))
                .foregroundStyle(.linearGradient(
                    colors: [TonicColors.accent, TonicColors.pro],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))

            VStack(spacing: 12) {
                Text(page.title)
                    .font(.title2)
                    .fontWeight(.bold)

                Text(page.description)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
    }
}

// MARK: - Preview

#Preview("Widget Onboarding") {
    WidgetOnboardingView()
}
