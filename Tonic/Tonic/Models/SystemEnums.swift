//
//  SystemEnums.swift
//  Tonic
//
//  Shared system enumeration types
//  Task ID: fn-3.7
//

import Foundation
import SwiftUI

// MARK: - Memory Pressure

/// System memory pressure state
public enum MemoryPressure: String, CaseIterable, Sendable {
    case normal = "Normal"
    case warning = "Warning"
    case critical = "Critical"

    /// Color representation for UI
    public var color: Color {
        switch self {
        case .normal: return DesignTokens.Colors.progressLow
        case .warning: return DesignTokens.Colors.progressMedium
        case .critical: return DesignTokens.Colors.progressHigh
        }
    }
}

// MARK: - Battery Health

/// Battery health state
public enum BatteryHealth: String, CaseIterable, Sendable {
    case good = "Good"
    case fair = "Fair"
    case poor = "Poor"
    case unknown = "Unknown"
}
