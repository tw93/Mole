# fn-3.5 Fix WeatherService location retention bug

## Description

The `TemporaryLocationManager` instance is created but not retained, causing it to be deallocated before CLLocationManager callbacks fire.

**File:** `Tonic/Services/WeatherService.swift` (lines 366-413)

**Bug:**
```swift
func getCurrentLocation() async throws -> CLLocation {
    let manager = TemporaryLocationManager()  // Deallocated before callback!
    return try await manager.fetchLocation { ... }
}
```

**Solution:** Store the manager instance in a property until callbacks complete.

## Acceptance

- [x] Add `private var temporaryLocationManager: TemporaryLocationManager?` property
- [x] Retain manager until location callbacks complete
- [x] Set to nil after success/error
- [ ] Test weather location works on first request (requires fn-3.8)

## Done summary
Fixed location retention by adding temporaryLocationManager property to WeatherService. The TemporaryLocationManager instance is now retained until location callbacks complete, preventing deallocation before CLLocationManager finishes fetching location.
## Evidence
- Commits:
- Tests:
- PRs: