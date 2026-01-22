# fn-2.9 Implement weather service and widget

## Description

Create weather widget using Open-Meteo API (free, no API key).

**Files to create:**
- `Tonic/Services/WeatherService.swift` - API client
- `Tonic/Services/LocationManager.swift` - Location services
- `Tonic/Models/WeatherData.swift` - Data models
- `Tonic/Views/MenuBarWidgets/WeatherWidgetView.swift`
- `Tonic/Views/MenuBarWidgets/WeatherDetailView.swift`

**WeatherService:**
- Fetch from Open-Meteo API: https://open-meteo.com/
- Current conditions + forecast
- 15-minute update interval
- Cache data for offline display

**LocationManager:**
- CoreLocation for auto-detection
- Manual location entry fallback
- Lat/lon storage for user preferences

**Compact view:**
- Weather icon (SF Symbols based on condition)
- Temperature (e.g., "72°")
- Location name

**Detail view:**
- Large temperature display
- Condition description
- Hourly forecast (graph)
- 7-day forecast list
- High/low, humidity, wind, UV
- Location selector

## Acceptance

- [ ] WeatherService fetches from Open-Meteo
- [ ] Auto-location via CoreLocation
- [ ] Manual location search fallback
- [ ] Compact view shows temp + icon
- [ ] Detail view with hourly/weekly forecast
- [ ] Celsius/Fahrenheit toggle preference
- [ ] Graceful offline handling with cached data
- [ ] 15-minute update interval

## Done summary
Implemented weather widget with Open-Meteo API (no API key required). Created WeatherService, WeatherData models, and WeatherWidgetView. Auto-location via CoreLocation with manual fallback. Shows current conditions with icon, hourly forecast graph, 7-day forecast list. C/F toggle supported with cached offline data. 15-minute update interval.
## Evidence
- Commits:
- Tests:
- PRs: