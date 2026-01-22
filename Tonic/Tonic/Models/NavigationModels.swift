//
//  NavigationModels.swift
//  Tonic
//
//  Shared navigation models
//

import SwiftUI

enum NavigationDestination: String, CaseIterable {
    case dashboard = "Dashboard"
    case systemCleanup = "System Cleanup"
    case appManager = "App Manager"
    case diskAnalysis = "Disk Analysis"
    case liveMonitoring = "Live Monitoring"
    case menuBarWidgets = "Menu Bar Widgets"
    case developerTools = "Developer Tools"
    case settings = "Settings"

    var systemImage: String {
        switch self {
        case .dashboard: return "chart.line.uptrend.xyaxis"
        case .systemCleanup: return "sparkles"
        case .appManager: return "app.badge"
        case .diskAnalysis: return "externaldrive.fill"
        case .liveMonitoring: return "gauge"
        case .menuBarWidgets: return "square.grid.2x2"
        case .developerTools: return "hammer.fill"
        case .settings: return "gear"
        }
    }
}
