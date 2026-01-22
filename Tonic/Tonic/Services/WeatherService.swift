//
//  WeatherService.swift
//  Tonic
//
//  Weather data service using Open-Meteo API
//  Task ID: fn-2.9
//

import Foundation
import CoreLocation
import SwiftUI

// MARK: - Weather Service

/// Weather data service using Open-Meteo API (free, no API key required)
@MainActor
@Observable
public final class WeatherService {

    public static let shared = WeatherService()

    // MARK: - Properties

    /// Current weather data
    public private(set) var currentWeather: WeatherResponse?

    /// Loading state
    public private(set) var isLoading = false

    /// Error state
    public private(set) var errorMessage: String?

    /// Last update time
    public private(set) var lastUpdateTime: Date?

    /// Selected location
    public private(set) var currentLocation: WeatherLocation = .currentLocation

    /// Saved locations
    public private(set) var savedLocations: [WeatherLocation] = []

    /// Temperature unit preference
    public var temperatureUnit: TemperatureUnit = .auto

    // MARK: - Constants

    private let baseURL = "https://api.open-meteo.com/v1"
    private let updateInterval: TimeInterval = 15 * 60 // 15 minutes
    private var updateTimer: Timer?

    // MARK: - Location Manager Retention

    /// Retain reference to temporary location manager during async fetch
    /// This prevents the manager from being deallocated before CLLocationManager callbacks complete
    private var temporaryLocationManager: TemporaryLocationManager?

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let savedLocations = "tonic.weather.savedLocations"
        static let temperatureUnit = "tonic.weather.temperatureUnit"
        static let currentLocationId = "tonic.weather.currentLocationId"
    }

    // MARK: - Initialization

    private init() {
        loadPreferences()
        loadCachedData()
    }

    // MARK: - Public Methods

    /// Start automatic weather updates
    public func startUpdates() {
        updateWeather()

        updateTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateWeather()
            }
        }
    }

    /// Stop automatic weather updates
    public func stopUpdates() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    /// Update weather for current location
    public func updateWeather() {
        if currentLocation.isCurrentLocation {
            updateWeatherForCurrentLocation()
        } else {
            updateWeatherForLocation(currentLocation)
        }
    }

    /// Set the location and fetch weather
    public func setLocation(_ location: WeatherLocation) {
        currentLocation = location
        savePreferences()
        updateWeather()
    }

    /// Add a saved location
    public func addLocation(_ location: WeatherLocation) {
        savedLocations.append(location)
        savePreferences()
    }

    /// Remove a saved location
    public func removeLocation(_ location: WeatherLocation) {
        savedLocations.removeAll { $0.id == location.id }
        savePreferences()
    }

    /// Set temperature unit
    public func setTemperatureUnit(_ unit: TemperatureUnit) {
        temperatureUnit = unit
        UserDefaults.standard.set(unit.rawValue, forKey: Keys.temperatureUnit)
    }

    // MARK: - Weather Fetching

    private func updateWeatherForCurrentLocation() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let location = try await getCurrentLocation()
                let weatherLocation = WeatherLocation(
                    name: "Current Location",
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    isCurrentLocation: true
                )

                try await fetchWeather(latitude: location.coordinate.latitude,
                                       longitude: location.coordinate.longitude,
                                       locationName: weatherLocation.name)

            } catch {
                errorMessage = "Location access denied. Please enable in System Settings."

                // Fall back to cached data
                if currentWeather == nil {
                    loadCachedData()
                }

                isLoading = false
            }
        }
    }

    private func updateWeatherForLocation(_ location: WeatherLocation) {
        isLoading = true
        errorMessage = nil

        Task {
            await fetchWeather(latitude: location.latitude,
                              longitude: location.longitude,
                              locationName: location.name)
        }
    }

    private func fetchWeather(latitude: Double, longitude: Double, locationName: String) async {
        do {
            // Build URL for Open-Meteo API
            var components = URLComponents(string: "\(baseURL)/forecast")!
            components.queryItems = [
                URLQueryItem(name: "latitude", value: "\(latitude)"),
                URLQueryItem(name: "longitude", value: "\(longitude)"),
                URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,wind_direction_10m"),
                URLQueryItem(name: "hourly", value: "temperature_2m,weather_code"),
                URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum,uv_index_max"),
                URLQueryItem(name: "timezone", value: "auto"),
                URLQueryItem(name: "forecast_days", value: "7")
            ]

            guard let url = components.url else {
                errorMessage = "Invalid URL"
                isLoading = false
                return
            }

            let (data, _) = try await URLSession.shared.data(from: url)

            let response = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)

            // Parse the response
            let weather = parseResponse(response, locationName: locationName)

            currentWeather = weather
            lastUpdateTime = Date()
            errorMessage = nil
            isLoading = false

            // Cache the data
            cacheWeatherData(weather)

        } catch {
            print("Weather fetch error: \(error)")

            // Load cached data if available
            if currentWeather == nil {
                loadCachedData()
            }

            errorMessage = "Failed to fetch weather data"
            isLoading = false
        }
    }

    private func parseResponse(_ response: OpenMeteoResponse, locationName: String) -> WeatherResponse {
        // Create date formatter for API response
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        dateFormatter.timeZone = TimeZone(secondsFromGMT: response.utc_offset_seconds)

        let dailyDateFormatter = DateFormatter()
        dailyDateFormatter.dateFormat = "yyyy-MM-dd"
        dailyDateFormatter.timeZone = TimeZone(secondsFromGMT: response.utc_offset_seconds)

        // Current weather
        let current = WeatherData(
            locationName: locationName,
            latitude: response.latitude,
            longitude: response.longitude,
            temperature: response.current.temperature_2m,
            feelsLike: response.current.apparent_temperature,
            humidity: response.current.relative_humidity_2m,
            windSpeed: response.current.wind_speed_10m,
            windDirection: response.current.wind_direction_10m,
            uvIndex: response.daily.uv_index_max.max() ?? 0,
            condition: WeatherCondition(wmoCode: response.current.weather_code),
            timestamp: Date()
        )

        // Hourly forecast (next 24 hours)
        let now = Date()
        let hourly: [HourlyForecast] = response.hourly.time.enumerated().compactMap { (index, timeString) -> HourlyForecast? in
            guard let time = dateFormatter.date(from: timeString) else { return nil }
            guard time > now, index < response.hourly.temperature_2m.count else { return nil }
            
            return HourlyForecast(
                time: time,
                temperature: response.hourly.temperature_2m[index],
                condition: WeatherCondition(wmoCode: response.hourly.weather_code[index]),
                precipitationChance: 0 // Open-Meteo provides daily, not hourly
            )
        }.prefix(24).map { $0 }

        // Daily forecast
        let daily = response.daily.time.enumerated().compactMap { index, dateString -> DailyForecast? in
            guard let date = dailyDateFormatter.date(from: dateString) else { return nil }
            guard index < response.daily.temperature_2m_max.count else { return nil }

            return DailyForecast(
                date: date,
                highTemp: response.daily.temperature_2m_max[index],
                lowTemp: response.daily.temperature_2m_min[index],
                condition: WeatherCondition(wmoCode: response.daily.weather_code[index]),
                precipitationChance: Double(response.daily.precipitation_probability_max[index]),
                precipitationAmount: response.daily.precipitation_sum[index]
            )
        }

        return WeatherResponse(current: current, hourly: Array(hourly), daily: daily)
    }

    // MARK: - Caching

    private func cacheWeatherData(_ weather: WeatherResponse) {
        if let encoded = try? JSONEncoder().encode(weather) {
            UserDefaults.standard.set(encoded, forKey: "tonic.weather.cachedData")
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "tonic.weather.cacheTime")
        }
    }

    private func loadCachedData() {
        guard let data = UserDefaults.standard.data(forKey: "tonic.weather.cachedData"),
              let weather = try? JSONDecoder().decode(WeatherResponse.self, from: data) else {
            return
        }

        // Check if cache is less than 1 hour old
        if let cacheTime = UserDefaults.standard.object(forKey: "tonic.weather.cacheTime") as? TimeInterval {
            let cacheDate = Date(timeIntervalSince1970: cacheTime)
            if Date().timeIntervalSince(cacheDate) < 3600 {
                currentWeather = weather
                lastUpdateTime = cacheDate
            }
        }
    }

    // MARK: - Preferences

    private func loadPreferences() {
        // Load temperature unit
        if let unitString = UserDefaults.standard.string(forKey: Keys.temperatureUnit),
           let unit = TemperatureUnit(rawValue: unitString) {
            temperatureUnit = unit
        }

        // Load saved locations
        if let data = UserDefaults.standard.data(forKey: Keys.savedLocations),
           let locations = try? JSONDecoder().decode([WeatherLocation].self, from: data) {
            savedLocations = locations
        }
    }

    private func savePreferences() {
        // Save saved locations
        if let encoded = try? JSONEncoder().encode(savedLocations) {
            UserDefaults.standard.set(encoded, forKey: Keys.savedLocations)
        }
    }

    // MARK: - Location Services

    private func getCurrentLocation() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            // Check if location services are enabled
            guard CLLocationManager.locationServicesEnabled() else {
                continuation.resume(throwing: LocationError.disabled)
                return
            }

            // Create and retain the location manager to prevent deallocation
            let locManager = TemporaryLocationManager()
            self.temporaryLocationManager = locManager

            locManager.fetchLocation { [weak self] result in
                // Clean up the retained reference
                self?.temporaryLocationManager = nil

                switch result {
                case .success(let location):
                    continuation.resume(returning: location)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Helper Methods

    /// Get formatted temperature string
    public func formatTemperature(_ celsius: Double) -> String {
        let value: Double
        switch temperatureUnit {
        case .celsius:
            value = celsius
        case .fahrenheit:
            value = (celsius * 9/5) + 32
        case .auto:
            // Use system locale
            let locale = Locale.current
            if locale.measurementSystem == .us {
                value = (celsius * 9/5) + 32
            } else {
                value = celsius
            }
        }

        return "\(Int(value))°"
    }
}

// MARK: - Location Error

enum LocationError: Error {
    case disabled
    case denied
    case timeout
    case failed
}

// MARK: - Temporary Location Manager

/// Temporary location manager for one-time location fetch
class TemporaryLocationManager: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private var completion: ((Result<CLLocation, Error>) -> Void)?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func fetchLocation(completion: @escaping (Result<CLLocation, Error>) -> Void) {
        self.completion = completion

        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.requestLocation()
        case .denied, .restricted:
            completion(.failure(LocationError.denied))
        @unknown default:
            completion(.failure(LocationError.denied))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.first {
            completion?(.success(location))
        }
        completion = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        completion?(.failure(error))
        completion = nil
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.requestLocation()
        case .denied, .restricted:
            completion?(.failure(LocationError.denied))
        default:
            break
        }
    }
}

// MARK: - Open-Meteo API Response Models

private struct OpenMeteoResponse: Codable {
    let latitude: Double
    let longitude: Double
    let utc_offset_seconds: Int
    let current: CurrentWeather
    let hourly: HourlyWeather
    let daily: DailyWeather

    struct CurrentWeather: Codable {
        let temperature_2m: Double
        let relative_humidity_2m: Double
        let apparent_temperature: Double
        let weather_code: Int
        let wind_speed_10m: Double
        let wind_direction_10m: Int
    }

    struct HourlyWeather: Codable {
        let time: [String]
        let temperature_2m: [Double]
        let weather_code: [Int]
    }

    struct DailyWeather: Codable {
        let time: [String]
        let weather_code: [Int]
        let temperature_2m_max: [Double]
        let temperature_2m_min: [Double]
        let precipitation_probability_max: [Int]
        let precipitation_sum: [Double]
        let uv_index_max: [Double]
    }
}
