# Mole Menu Bar App

A native macOS menu bar application that displays real-time system metrics from `mo status`, similar to iStatMenus.

## Features

- **Real-time CPU bar graph** in the menu bar
- **Comprehensive metrics dropdown** showing:
  - CPU usage, per-core stats, and load averages
  - Memory usage and pressure
  - Disk space and I/O rates
  - Network upload/download speeds
  - Battery level, health, and cycles
  - Thermal information (CPU/GPU temps, fan speed, power)
  - Top 3 CPU-consuming processes
- **Quick Actions** to run `mo clean`, `mo optimize`, and `mo analyze`
- **Preferences window** with customizable settings
- **Launch at login** option
- **Health score** indicator

## Architecture

The app uses a hybrid Swift + Go architecture:
- **Swift/SwiftUI** for the native macOS menu bar UI
- **Go shared library** (libmolemetrics.dylib) for metrics collection
- **C bridging** to call Go functions from Swift

All metrics collection code is shared with the `mo status` command through the `pkg/metrics` package.

## Prerequisites

- macOS 12.0 or later
- Xcode 14.0 or later
- Go 1.24.0 or later (already required for Mole)
- Mole installed (`mo` command available)

## Building the App

### Step 1: Build the Go Shared Library

```bash
cd /Users/shravan/Downloads/Mole-main
make menubar-lib
```

This creates:
- `bin/libmolemetrics.dylib` - The shared library
- `bin/libmolemetrics.h` - C header file

### Step 2: Create the Xcode Project

1. Open Xcode
2. Create a new project: **File > New > Project**
3. Choose **macOS > App**
4. Settings:
   - **Product Name:** MoleMenuBar
   - **Team:** Your development team
   - **Organization Identifier:** com.mole
   - **Interface:** SwiftUI
   - **Language:** Swift
   - **Location:** Select `menubar-app/` directory

5. Add the Swift source files to the project:
   - Drag all `.swift` files from `menubar-app/MoleMenuBar/` into the Xcode project navigator
   - Make sure "Copy items if needed" is unchecked (they're already in the right place)
   - Add:
     - MoleMenuBarApp.swift
     - MenuBarController.swift
     - MetricsManager.swift
     - MenuBarIconView.swift
     - QuickActionsRunner.swift
     - PreferencesWindow.swift

6. Add the bridging header:
   - Go to **Build Settings**
   - Search for "Objective-C Bridging Header"
   - Set value to: `MoleMenuBar/MoleMenuBar-Bridging-Header.h`

7. Add the Go shared library:
   - Drag `bin/libmolemetrics.dylib` into the project
   - In the dialog, check "Copy items if needed"
   - In **Build Phases > Embed Libraries**, ensure the dylib is listed
   - Set "Code Sign On Copy" to checked

8. Configure build settings:
   - **Target > General > Deployment Target:** macOS 12.0
   - **Target > Signing & Capabilities:**
     - Add capability: **App Sandbox** (set to OFF in entitlements)
     - Add capability: **Apple Events**
   - **Target > Info:**
     - Replace Info.plist with the one in `menubar-app/MoleMenuBar/Info.plist`
   - **Target > Build Settings:**
     - **Library Search Paths:** Add `$(PROJECT_DIR)/../bin`
     - **Runpath Search Paths:** Add `@executable_path/../Frameworks`

9. Add the entitlements file:
   - Go to **Target > Signing & Capabilities**
   - Ensure `MoleMenuBar.entitlements` is set as the entitlements file

### Step 3: Build and Run

1. Select **Product > Build** (⌘B)
2. If successful, select **Product > Run** (⌘R)
3. The menu bar icon should appear in the top right

## Alternative: Build Script (Recommended)

Use the provided build script for automatic compilation:

```bash
# From project root
bash scripts/build-menubar.sh

# Or use the Makefile
make menubar-app
```

This will:
1. Build the Go shared library
2. Compile Swift files with `swiftc`
3. Create the app bundle structure
4. Copy the dylib into the app bundle
5. Fix library paths with `install_name_tool`
6. Code sign the app
7. Create signed app in `menubar-app/build/MoleMenuBar.app`

The script uses direct `swiftc` compilation instead of Xcode, making it easier to automate and integrate with CI/CD.

## Usage

1. **Menu Bar Icon:** Shows a real-time CPU bar graph
2. **Click the icon:** Opens the metrics dropdown menu
3. **Quick Actions:** Click any action to open Terminal and run the command
4. **Preferences:** Customize update interval, metrics display, and notifications

## Troubleshooting

### "Cannot load metrics library"
- Ensure `make menubar-lib` completed successfully
- Check that `libmolemetrics.dylib` is in the app bundle: `MoleMenuBar.app/Contents/MacOS/`
- Verify the dylib is signed: `codesign -dv libmolemetrics.dylib`

### "Metrics manager not initialized"
- The Go library initialization failed
- Check Console.app for error messages
- Ensure you're running on macOS (not Linux/Windows)

### App won't launch
- Check that all Swift files are included in the target
- Verify the bridging header path is correct
- Ensure the Info.plist has `LSUIElement` set to `true`

### Terminal won't open for Quick Actions
- Grant Terminal automation permissions: **System Settings > Privacy & Security > Automation**
- Ensure the `mo` command is in your PATH

## Thread Safety and Memory Management

The app is designed with careful attention to thread safety and memory management:

### Memory Management
- **C String Lifecycle**: All C strings returned from Go are freed using `defer { FreeString(...) }`
- **Automatic Cleanup**: Ensures memory is freed even if errors occur
- **No Memory Leaks**: Proper cleanup prevents memory accumulation over time

### Thread Safety
- **Background Metrics Collection**: Go library calls happen on `DispatchQueue.global(qos: .userInitiated)`
- **Main Thread UI Updates**: All UI changes (button title, menus) use `DispatchQueue.main.async`
- **Weak References**: Closures use `[weak self]` to prevent retain cycles
- **Animation Safety**: Menu operations wrapped in main queue to prevent window animation crashes

These patterns prevent the SIGSEGV crashes that can occur from:
- Memory corruption due to improper C string handling
- UI updates on background threads
- Race conditions in menu/window animations

## Development

### Project Structure

```
menubar-app/
├── MoleMenuBar/
│   ├── MoleMenuBarApp.swift          # Main app entry point
│   ├── MenuBarController.swift       # Menu bar logic and UI
│   ├── MetricsManager.swift          # Go library interface
│   ├── MenuBarIconView.swift         # CPU bar graph view
│   ├── QuickActionsRunner.swift      # CLI command executor
│   ├── PreferencesWindow.swift       # Settings UI
│   ├── MoleMenuBar-Bridging-Header.h # C/Swift bridging
│   ├── Info.plist                    # App metadata
│   └── MoleMenuBar.entitlements      # App capabilities
└── README.md
```

### Modifying Metrics Display

To change which metrics are shown, edit `MenuBarController.swift`:
- `createMenu(with:)` method builds the menu
- Add/remove sections as needed
- Use `createMenuItem(label:value:)` helper for consistency

### Customizing the Icon

To change the menu bar icon style, edit `MenuBarIconView.swift`:
- `draw(_:)` method renders the bars
- Adjust `barWidth`, `barSpacing`, `maxHistoryCount` for different looks
- Modify `colorForUsage(_:)` for different color thresholds

### Adding New Preferences

To add settings, edit `PreferencesWindow.swift`:
- Add `@AppStorage` property for new setting
- Add UI controls in the appropriate tab
- Access settings from other classes via `UserDefaults.standard`

## Distribution

### For Personal Use
1. Build the app in Xcode
2. Copy `MoleMenuBar.app` to `/Applications/`
3. Right-click > Open (to bypass Gatekeeper first time)

### For Public Distribution
1. Sign with Developer ID certificate
2. Notarize with Apple: `xcrun notarytool submit`
3. Staple the ticket: `xcrun stapler staple MoleMenuBar.app`
4. Create DMG or distribute via Homebrew Cask

## License

Same license as Mole (check main repository).

## Contributing

Contributions welcome! Please ensure:
- Swift code follows Swift style guide
- Changes don't break the existing `mo status` command
- Both terminal and menu bar apps continue to work
