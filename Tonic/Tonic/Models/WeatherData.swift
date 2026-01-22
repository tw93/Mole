//
//  WeatherData.swift
//  Tonic
//
//  Weather data models
//  Task ID: fn-2.9
//

import Foundation
import SwiftUI

// MARK: - Weather Condition

/// Weather condition types
public enum WeatherCondition: String, Codable, Sendable {
    case clear = "clear"
    case cloudy = "cloudy"
    case partlyCloudy = "partly_cloudy"
    case rain = "rain"
    case drizzle = "drizzle"
    case snow = "snow"
    case thunderstorm = "thunderstorm"
    case fog = "fog"
    case mist = "mist"
    case unknown = "unknown"

    /// SF Symbol icon for the condition
    public var icon: String {
        switch self {
        case .clear: return "sun.max.fill"
        case .cloudy: return "cloud.fill"
        case .partlyCloudy: return "cloud.sun.fill"
        case .rain: return "cloud.rain.fill"
        case .drizzle: return "cloud.drizzle.fill"
        case .snow: return "cloud.snow.fill"
        case .thunderstorm: return "cloud.bolt.rain.fill"
        case .fog: return "cloud.fog.fill"
        case .mist: return "cloud.fog"
        case .unknown: return "cloud.question"
        }
    }

    /// Display name
    public var displayName: String {
        switch self {
        case .clear: return "Clear"
        case .cloudy: return "Cloudy"
        case .partlyCloudy: return "Partly Cloudy"
        case .rain: return "Rain"
        case .drizzle: return "Drizzle"
        case .snow: return "Snow"
        case .thunderstorm: return "Thunderstorm"
        case .fog: return "Fog"
        case .mist: return "Mist"
        case .unknown: return "Unknown"
        }
    }

    /// Initialize from WMO weather code
    public init(wmoCode: Int) {
        switch wmoCode {
        case 0: self = .clear
        case 1, 2, 3: self = .partlyCloudy
        case 45, 48: self = .fog
        case 51, 53, 55: self = .drizzle
        case 56, 57: self = .drizzle
        case 61, 63, 65: self = .rain
        case 71, 73, 75, 77: self = .snow
        case 80, 81, 82: self = .rain
        case 85, 86: self = .snow
        case 95, 96, 99: self = .thunderstorm
        default: self = .cloudy
        }
    }
}

// MARK: - Weather Data

/// Current weather data
public struct WeatherData: Codable, Sendable {
    public let locationName: String
    public let latitude: Double
    public let longitude: Double
    public let temperature: Double
    public let feelsLike: Double
    public let humidity: Double
    public let windSpeed: Double
    public let windDirection: Int
    public let uvIndex: Double
    public let condition: WeatherCondition
    public let timestamp: Date

    public init(
        locationName: String,
        latitude: Double,
        longitude: Double,
        temperature: Double,
        feelsLike: Double,
        humidity: Double,
        windSpeed: Double,
        windDirection: Int,
        uvIndex: Double,
        condition: WeatherCondition,
        timestamp: Date = Date()
    ) {
        self.locationName = locationName
        self.latitude = latitude
        self.longitude = longitude
        self.temperature = temperature
        self.feelsLike = feelsLike
        self.humidity = humidity
        self.windSpeed = windSpeed
        self.windDirection = windDirection
        self.uvIndex = uvIndex
        self.condition = condition
        self.timestamp = timestamp
    }
}

// MARK: - Hourly Forecast

/// Hourly weather forecast
public struct HourlyForecast: Codable, Sendable, Identifiable {
    public let id = UUID()
    public let time: Date
    public let temperature: Double
    public let condition: WeatherCondition
    public let precipitationChance: Double

    public init(time: Date, temperature: Double, condition: WeatherCondition, precipitationChance: Double = 0) {
        self.time = time
        self.temperature = temperature
        self.condition = condition
        self.precipitationChance = precipitationChance
    }

    public var hourString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "ha"
        return formatter.string(from: time).lowercased()
    }
}

// MARK: - Daily Forecast

/// Daily weather forecast
public struct DailyForecast: Codable, Sendable, Identifiable {
    public let id = UUID()
    public let date: Date
    public let highTemp: Double
    public let lowTemp: Double
    public let condition: WeatherCondition
    public let precipitationChance: Double
    public let precipitationAmount: Double

    public init(
        date: Date,
        highTemp: Double,
        lowTemp: Double,
        condition: WeatherCondition,
        precipitationChance: Double = 0,
        precipitationAmount: Double = 0
    ) {
        self.date = date
        self.highTemp = highTemp
        self.lowTemp = lowTemp
        self.condition = condition
        self.precipitationChance = precipitationChance
        self.precipitationAmount = precipitationAmount
    }

    public var dayName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "E"
        return formatter.string(from: date)
    }

    public var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }
}

// MARK: - Weather Location

/// Saved weather location
public struct WeatherLocation: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let latitude: Double
    public let longitude: Double
    public let isCurrentLocation: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        latitude: Double,
        longitude: Double,
        isCurrentLocation: Bool = false
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.isCurrentLocation = isCurrentLocation
    }

    public static let currentLocation = WeatherLocation(
        name: "Current Location",
        latitude: 0,
        longitude: 0,
        isCurrentLocation: true
    )
}

// MARK: - Temperature Unit

/// Temperature unit preferences
public enum TemperatureUnit: String, CaseIterable, Codable, Sendable {
    case celsius = "celsius"
    case fahrenheit = "fahrenheit"
    case auto = "auto"

    public var displayName: String {
        switch self {
        case .celsius: return "°C"
        case .fahrenheit: return "°F"
        case .auto: return "Auto"
        }
    }
}

// MARK: - Temperature Formatting

extension Double {
    /// Format temperature based on unit preference
    public func formattedTemperature(unit: TemperatureUnit) -> String {
        let value = switch unit {
        case .celsius: self
        case .fahrenheit: (self * 9/5) + 32
        case .auto: self // Will use system locale in UI
        }

        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0

        if let formatted = formatter.string(from: NSNumber(value: value)) {
            switch unit {
            case .celsius: return "\(formatted)°C"
            case .fahrenheit: return "\(formatted)°F"
            case .auto: return "\(formatted)°"
            }
        }

        return "\(Int(value))°"
    }
}

// MARK: - Complete Weather Response

/// Complete weather data including current, hourly, and daily
public struct WeatherResponse: Codable, Sendable {
    public let current: WeatherData
    public let hourly: [HourlyForecast]
    public let daily: [DailyForecast]

    public init(current: WeatherData, hourly: [HourlyForecast], daily: [DailyForecast]) {
        self.current = current
        self.hourly = hourly
        self.daily = daily
    }
}
