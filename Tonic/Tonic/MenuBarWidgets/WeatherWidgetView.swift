//
//  WeatherWidgetView.swift
//  Tonic
//
//  Weather widget views
//  Task ID: fn-2.9
//

import SwiftUI
import Charts

// MARK: - Weather Compact View

/// Compact menu bar view for Weather widget
public struct WeatherCompactView: View {

    @State private var weatherService = WeatherService.shared

    public init() {}

    public var body: some View {
        HStack(spacing: 4) {
            if let weather = weatherService.currentWeather {
                Image(systemName: weather.current.condition.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.yellow)

                Text(weatherService.formatTemperature(weather.current.temperature))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)

                // Small location indicator for non-current locations
                if !weatherService.currentLocation.isCurrentLocation {
                    Image(systemName: "location.fill")
                        .font(.system(size: 6))
                        .foregroundColor(.secondary)
                }
            } else if weatherService.isLoading {
                ProgressView()
                    .scaleEffect(0.5)
            } else {
                Image(systemName: "cloud.question")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 22)
    }
}

// MARK: - Weather Detail View

/// Detailed popover view for Weather widget
public struct WeatherDetailView: View {

    @State private var weatherService = WeatherService.shared

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            if weatherService.isLoading && weatherService.currentWeather == nil {
                loadingView
            } else if let weather = weatherService.currentWeather {
                contentView(weather: weather)
            } else {
                errorView
            }
        }
        .frame(width: 320, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            if let weather = weatherService.currentWeather {
                Image(systemName: weather.current.condition.icon)
                    .font(.title2)
                    .foregroundColor(.yellow)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(weatherService.currentLocation.name)
                    .font(.headline)

                if let updateTime = weatherService.lastUpdateTime {
                    Text("Updated \(formatTime(updateTime))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button {
                weatherService.updateWeather()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(weatherService.isLoading)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func contentView(weather: WeatherResponse) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                // Current conditions
                currentConditionsSection(weather: weather)

                // Hourly forecast graph
                hourlyForecastSection(weather: weather)

                // 7-day forecast
                dailyForecastSection(weather: weather)

                // Weather details
                weatherDetailsSection(weather: weather)
            }
            .padding()
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading weather data...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(.secondary)

            Text(weatherService.errorMessage ?? "Weather data unavailable")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Button("Retry") {
                weatherService.updateWeather()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func currentConditionsSection(weather: WeatherResponse) -> some View {
        VStack(spacing: 16) {
            // Large temperature display
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(weatherService.formatTemperature(weather.current.temperature))
                    .font(.system(size: 48, weight: .light, design: .rounded))
                    .foregroundColor(.primary)

                Text(weatherService.formatTemperature(weather.current.feelsLike))
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)

                Text("feels like")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Condition description
            Text(weather.current.condition.displayName)
                .font(.subheadline)
                .foregroundColor(.secondary)

            // High/low for today
            if let today = weather.daily.first {
                HStack(spacing: 16) {
                    Label("H: \(weatherService.formatTemperature(today.highTemp))", systemImage: "arrow.up")
                        .font(.caption)
                        .foregroundColor(.red)

                    Label("L: \(weatherService.formatTemperature(today.lowTemp))", systemImage: "arrow.down")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }

    private func hourlyForecastSection(weather: WeatherResponse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hourly Forecast")
                .font(.subheadline)
                .foregroundColor(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Array(weather.hourly.prefix(12).enumerated()), id: \.element.id) { index, hour in
                        VStack(spacing: 8) {
                            Text(index == 0 ? "Now" : hour.hourString)
                                .font(.caption2)
                                .foregroundColor(.secondary)

                            Image(systemName: hour.condition.icon)
                                .font(.system(size: 14))
                                .foregroundColor(.yellow)

                            Text(weatherService.formatTemperature(hour.temperature))
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .frame(width: 50)
                    }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private func dailyForecastSection(weather: WeatherResponse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("7-Day Forecast")
                .font(.subheadline)
                .foregroundColor(.secondary)

            VStack(spacing: 8) {
                ForEach(weather.daily) { day in
                    HStack(spacing: 12) {
                        Text(day.dayName)
                            .font(.caption)
                            .foregroundColor(day.isToday ? .primary : .secondary)
                            .frame(width: 40, alignment: .leading)

                        Image(systemName: day.condition.icon)
                            .font(.system(size: 14))
                            .foregroundColor(.yellow)
                            .frame(width: 20)

                        HStack(spacing: 8) {
                            Text(weatherService.formatTemperature(day.highTemp))
                                .font(.caption)
                                .foregroundColor(.red)

                            Text(weatherService.formatTemperature(day.lowTemp))
                                .font(.caption)
                                .foregroundColor(.blue)
                        }

                        Spacer()

                        // Precipitation indicator
                        if day.precipitationChance > 20 {
                            HStack(spacing: 4) {
                                Image(systemName: "drop.fill")
                                    .font(.caption2)
                                    .foregroundColor(.blue)

                                Text("\(Int(day.precipitationChance))%")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private func weatherDetailsSection(weather: WeatherResponse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details")
                .font(.subheadline)
                .foregroundColor(.secondary)

            VStack(spacing: 10) {
                detailRow(label: "Humidity", value: "\(Int(weather.current.humidity))%", icon: "drop.fill")
                detailRow(label: "Wind", value: "\(Int(weather.current.windSpeed)) km/h", icon: "wind")
                detailRow(label: "UV Index", value: "\(Int(weather.current.uvIndex))", icon: "sun.max")

                let uvValue = Int(weather.current.uvIndex)
                let uvColor = uvColor(for: uvValue)
                Text(uvDescription(for: uvValue))
                    .font(.caption)
                    .foregroundColor(uvColor)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private func detailRow(label: String, value: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 20)

            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }

    private func uvColor(for uvIndex: Int) -> Color {
        switch uvIndex {
        case 0...2: return .green
        case 3...5: return .yellow
        case 6...7: return .orange
        case 8...10: return .red
        default: return .purple
        }
    }

    private func uvDescription(for uvIndex: Int) -> String {
        switch uvIndex {
        case 0...2: return "Low"
        case 3...5: return "Moderate"
        case 6...7: return "High"
        case 8...10: return "Very High"
        default: return "Extreme"
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Weather Status Item

/// Manages the Weather widget's NSStatusItem
@MainActor
public final class WeatherStatusItem: WidgetStatusItem {

    public override init(widgetType: WidgetType = .weather, configuration: WidgetConfiguration) {
        super.init(widgetType: widgetType, configuration: configuration)

        // Start weather updates
        WeatherService.shared.startUpdates()
    }

    // Uses base WidgetStatusItem.createCompactView() which respects configuration
    
    public override func createCompactView() -> AnyView {
        AnyView(WeatherCompactView())
    }

    public override func createDetailView() -> AnyView {
        AnyView(WeatherDetailView())
    }
}

// MARK: - Preview

#Preview("Weather Detail") {
    WeatherDetailView()
        .frame(width: 320, height: 500)
}
