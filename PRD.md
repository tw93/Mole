# Product Requirements Document (PRD)

## Tonic - Native macOS System Management

**Version:** 1.0  
**Status:** In Development  
**Last Updated:** January 2026

---

## Table of Contents

1. [Product Overview](#1-product-overview)
2. [Problem Statement](#2-problem-statement)
3. [Product Vision](#3-product-vision)
4. [Target Users](#4-target-users)
5. [Core Features](#5-core-features)
6. [Feature Specifications](#6-feature-specifications)
7. [Technical Requirements](#7-technical-requirements)
8. [User Experience](#8-user-experience)
9. [Current State](#9-current-state)
10. [Success Metrics](#10-success-metrics)
11. [Freemium Model](#11-freemium-model)

---

## 1. Product Overview

Tonic is a native macOS application that provides comprehensive system management capabilities through a beautiful, modern interface. It combines disk cleanup, performance monitoring, app management, and real-time menu bar widgets into a single, polished application.

Unlike CLI-based tools or web utilities, Tonic leverages native macOS frameworks (SwiftUI, IOKit, CoreLocation) to provide:
- True native performance and responsiveness
- Deep integration with macOS system services
- Real-time hardware monitoring without external dependencies
- Safe, reversible cleanup operations with preview capabilities

### Product Positioning

```
┌─────────────────────────────────────────────────────────────┐
│                    Tonic Position                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   Simple Tools                    Tonic                    │Commercial Suites
│   (CleanMyMac X,                   →                        │  (MacKeeper,  │
│    DaisyDisk, etc.)                    Native macOS         │   Dr. Cleaner)│
│                                           Excellence        │               │
│                                                             │
│   • CLI-based or            • Native SwiftUI               │   • Bloated    │
│     web-based               • Real-time widgets           │   • Upselling  │
│   • Limited polish          • Deep macOS integration      │   • Subscription│
│   • Fragmented features     • One-time purchase option    │     fatigue    │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Problem Statement

### The Problem

macOS users face several challenges in maintaining their systems:

1. **Hidden Disk Consumption**
   - Cache files accumulate silently (browser caches, app caches, system caches)
   - Log files grow unbounded over time
   - Development artifacts (node_modules, build outputs) consume gigabytes
   - Old iOS device backups, Xcode derived data, and Docker images hide in obscure locations

2. **Lack of Visibility**
   - No native way to see what's consuming disk space
   - Real-time system monitoring requires multiple tools or Terminal commands
   - Menu bar widgets for system stats are either absent or require separate installations
   - Memory pressure and CPU usage aren't visible without launching Activity Monitor

3. **Unsafe Cleanup Tools**
   - CLI tools require command-line expertise and risk permanent data loss
   - Existing apps lack proper safety mechanisms (whitelists, previews)
   - No granular control over what gets deleted
   - Orphaned app files persist after uninstallation

4. **Fragmented User Experience**
   - Multiple apps needed for different maintenance tasks
   - No unified dashboard for system health
   - Settings scattered across System Preferences
   - Menu bar widgets require separate installations

### User Pain Points

| Pain Point | Current Workaround | User Frustration |
|------------|-------------------|------------------|
| "My disk is full but I don't know what's taking space" | DaisyDisk, Disk Inventory X | Third-party tool, paid, or CLI |
| "I want to see CPU/Memory in my menu bar" | iStatMenus, Stats | Paid apps, menu bar clutter |
| "I accidentally deleted important files" | Time Machine restore | No preview before cleanup |
| "Apps leave behind files after uninstall" | AppCleaner, manual deletion | Additional tool needed |

---

## 3. Product Vision

### Vision Statement

> "Create the single, indispensable tool for Mac users to maintain, optimize, and monitor their systems with a beautiful native experience that respects user data and privacy."

### Core Values

1. **Native Excellence** - Every feature built with native macOS technologies for optimal performance and integration
2. **Safety First** - All destructive operations include preview, confirmation, and undo capabilities
3. **Transparency** - Users see exactly what will be cleaned, why, and how much space will be reclaimed
4. **Performance** - Fast scans, low memory footprint, no background processes unless needed
5. **Privacy** - No data collection, no cloud processing of personal files, local-first architecture

### Product Principles

- **Single Window** - Most tasks accessible from the main dashboard
- **Progressive Disclosure** - Simple by default, powerful when needed
- **Safe Defaults** - Conservative cleanup recommendations, protected system files
- **Instant Feedback** - Real-time progress, clear success/error states

---

## 4. Target Users

### Primary Users

#### Power Users and Developers
- **Demographics**: 25-45 years old, technical profession
- **Devices**: MacBook Pro/Mac Studio, typically Apple Silicon
- **Needs**:
  - Clean development artifacts (node_modules, build folders, Docker)
  - Real-time system monitoring during development
  - Complete app uninstallation including preferences
  - Customizable menu bar widgets

**User Story:**
> "As a developer, I want to quickly identify and clean up large development folders so I can free up disk space for new projects without manually hunting through my file system."

#### Creative Professionals
- **Demographics**: 20-50 years old, design/video/music production
- **Devices**: MacBook Pro, iMac Pro, Mac Studio
- **Needs**:
  - Large file identification and management
  - Cache cleanup for creative applications
  - Disk usage visualization (treemap)
  - System performance monitoring during rendering

**User Story:**
> "As a video editor, I want to see which projects are taking the most space and quickly clean up cache files so I can continue working without disk space warnings."

#### General Mac Users
- **Demographics**: All ages, non-technical background
- **Devices**: Any Mac running macOS 14+
- **Needs**:
  - Simple, one-click cleanup
  - Clear explanations of what will be cleaned
  - Safe operation without risk of data loss
  - Health score showing system condition

**User Story:**
> "As a casual Mac user, I want a simple way to clean up my Mac without understanding technical details so I can keep my computer running smoothly."

### Secondary Users

- **IT Administrators** - Deployable to managed Macs for standardization
- **Family Tech Support** - Recommended to less technical family members
- **Small Business Owners** - Free alternative to paid system management suites

---

## 5. Core Features

### Feature Overview

| Feature | Status | Description |
|---------|--------|-------------|
| Dashboard | Implemented | System health score, quick actions, recommendations |
| Smart Scan | Implemented | Multi-stage scanning with health scoring |
| Deep Clean | Implemented | 10 cleanup categories with progress tracking |
| Disk Analysis | Implemented | Directory browser with large file identification |
| Disk Map | Implemented | Treemap visualization of disk usage |
| System Monitoring | Implemented | Real-time CPU, Memory, Disk, Network, Battery |
| Menu Bar Widgets | Implemented | 7 widget types with customization |
| App Inventory | Implemented | Categorized app list with search and filters |
| App Uninstall | Implemented | Complete removal with associated files |
| Notification Rules | Implemented | Custom alerts based on system metrics |
| Weather Widget | Implemented | Current conditions and 7-day forecast |
| Preferences | Implemented | Theme, updates, permissions management |
| Onboarding | Implemented | 4-page wizard for first-time users |

### Feature Groupings

#### System Cleanup
- Smart Scan (4-stage analysis)
- Deep Clean (10 categories)
- Hidden Space Scanner
- Cloud Storage Detection
- Collector Bin (staging area)

#### System Monitoring
- Real-time Dashboard
- System Status Dashboard
- Menu Bar Widgets (7 types)
- Notification Rules Engine

#### App Management
- App Inventory (8 categories)
- App Uninstaller
- App Update Detection

#### Disk Analysis
- Directory Browser
- Large File Scanner
- Treemap Visualization

---

## 6. Feature Specifications

### 6.1 Dashboard

**Description:** Main entry point showing system health score, quick actions, real-time stats, and recommendations.

**User Flow:**
1. User opens Tonic
2. Sees health score (0-100) with color-coded rating
3. Reviews recommendations for improvement
4. Clicks quick action button to perform task
5. Views recent activity timeline

**Requirements:**

| Requirement | Priority | Description |
|-------------|----------|-------------|
| Health Score Display | Must Have | Show 0-100 score with circular progress indicator |
| Quick Actions | Must Have | 4 buttons: Smart Scan, Deep Clean, Optimize, Analyze Disk |
| Real-time Stats | Must Have | Storage, Memory, CPU percentages update every 2s |
| Recommendations | Must Have | Actionable items with space estimates |
| Activity Timeline | Should Have | Show recent scan/clean operations |

**Acceptance Criteria:**
- [ ] Health score displays within 1 second of app launch
- [ ] Quick action buttons trigger correct view navigation
- [ ] Stats update in real-time without lag
- [ ] Recommendations show potential space reclamation

**Technical Notes:**
- Health score calculated from: disk usage (25%), cache files (25%), app issues (25%), performance issues (25%)
- Stats fetched from `WidgetDataManager.shared`

---

### 6.2 Smart Scan

**Description:** Multi-stage scanning engine that analyzes the system and generates a health score with actionable recommendations.

**User Flow:**
1. User clicks "Smart Scan" on dashboard
2. Scan progresses through 4 stages with visual feedback
3. Results show health score and categorized recommendations
4. User selects recommendations to clean
5. Clean operation executes with progress

**Scanning Stages:**

| Stage | Duration | Actions |
|-------|----------|---------|
| Preparing | ~0.5s | Initialize, load preferences |
| Scanning Disk | Variable | Enumerate caches, logs, temp files |
| Checking Apps | Variable | Identify unused apps, duplicates, orphaned files |
| Analyzing System | Variable | Detect hidden space, performance issues |

**Requirements:**

| Requirement | Priority | Description |
|-------------|----------|-------------|
| Stage Progression | Must Have | Show current stage with progress percentage |
| Cancel Operation | Must Have | Allow user to cancel mid-scan |
| Recommendation Types | Must Have | Cache, Logs, Temp Files, Duplicates, Large Files, Hidden Space |
| Health Score | Must Have | Calculate 0-100 score based on findings |
| Selective Clean | Should Have | Allow user to select specific recommendations |

**Acceptance Criteria:**
- [ ] Scan completes within 30 seconds on typical user system
- [ ] All 4 stages display with accurate progress
- [ ] Health score matches manual calculation of findings
- [ ] Recommendations show expected space reclamation

---

### 6.3 Deep Clean

**Description:** Comprehensive cleanup across 10 categories with detailed progress tracking.

**Cleanup Categories:**

| Category | Scan Time | Typical Space |
|----------|-----------|---------------|
| System Cache | Fast | 1-5 GB |
| User Cache | Medium | 5-20 GB |
| Log Files | Fast | 0.5-2 GB |
| Temporary Files | Fast | 0.5-2 GB |
| Browser Cache | Fast | 1-5 GB |
| Downloads | Fast | Variable |
| Trash | Fast | Variable |
| Development | Slow | 10-50 GB |
| Docker | Medium | 5-20 GB |
| Xcode | Slow | 10-30 GB |

**Requirements:**

| Requirement | Priority | Description |
|-------------|----------|-------------|
| Category Selection | Must Have | Toggle individual categories |
| Pre-scan Display | Must Have | Show items to be cleaned before execution |
| Progress Tracking | Must Have | Real-time progress during cleanup |
| Space Freed | Must Have | Display total bytes freed after completion |
| Whitelist Support | Should Have | Exclude user-specified paths |

**Acceptance Criteria:**
- [ ] Each category can be independently enabled/disabled
- [ ] Pre-scan shows item count and total size
- [ ] Progress updates every 500ms during cleanup
- [ ] Final result shows accurate bytes freed

---

### 6.4 System Monitoring

**Description:** Real-time display of system metrics with configurable refresh rates.

**Metrics Monitored:**

| Metric | Source | Update Frequency |
|--------|--------|------------------|
| CPU Usage | `host_processor_info()` | 1-5s configurable |
| Memory Usage | `vm_statistics64()` | 1-5s configurable |
| Disk Usage | `getfsstat()` | 5-10s |
| Network Activity | `sysctl` NET_RT_IFLIST2 | 1-5s configurable |
| GPU Stats | IOKit (Apple Silicon) | 2s |
| Battery | IOKit `IOPS` | 5s |

**Requirements:**

| Requirement | Priority | Description |
|-------------|----------|-------------|
| Metric Display | Must Have | Show current value with unit |
| History Graph | Should Have | Sparkline showing recent values |
| Process List | Should Have | Top CPU/memory consuming processes |
| Customizable Interval | Could Have | User-settable refresh rate |

**Acceptance Criteria:**
- [ ] Metrics update within 1 second of actual change
- [ ] Values match Activity Monitor within 1% tolerance
- [ ] No memory leak during extended monitoring sessions

---

### 6.5 Menu Bar Widgets

**Description:** Real-time system metrics displayed as separate menu bar items.

**Widget Types:**

| Widget | Data Source | Display Modes |
|--------|-------------|---------------|
| CPU | `host_processor_info()` | Icon, Icon+Value, Icon+Value+Sparkline |
| Memory | `vm_statistics64()` | Icon, Icon+Value, Icon+Value+Sparkline |
| Disk | `getfsstat()` | Icon, Icon+Value |
| Network | `sysctl` | Icon, Icon+Value |
| GPU | IOKit AGX | Icon, Icon+Value |
| Battery | IOKit IOPS | Icon, Icon+Value |
| Weather | Open-Meteo API | Icon, Icon+Value, Icon+Value+Forecast |

**Requirements:**

| Requirement | Priority | Description |
|-------------|----------|-------------|
| Independent Widgets | Must Have | Each metric has separate NSStatusItem |
| Display Modes | Must Have | 3 modes per widget |
| Customization | Must Have | Enable/disable, reorder, colors |
| Onboarding | Must Have | First-run widget setup wizard |
| Click Behavior | Must Have | Opens detail popover |

**Acceptance Criteria:**
- [ ] Each enabled widget appears in menu bar
- [ ] Widgets update at configured interval
- [ ] Click opens detail popover with graphs
- [ ] Settings persist across app restarts

---

### 6.6 App Management

**Description:** Inventory of installed applications with search, filter, and uninstall capabilities.

**Inventory Categories:**

| Category | Examples |
|----------|----------|
| Apps | Standard .app bundles |
| Extensions | Safari, Finder, System Extensions |
| Preference Panes | System Preferences panes |
| Quick Look Plugins | .qlgenerator files |
| Spotlight Importers | .mdimporter bundles |
| Frameworks | .framework bundles |
| System Utilities | Built-in system apps |
| Login Items | Apps launching at login |

**Requirements:**

| Requirement | Priority | Description |
|-------------|----------|-------------|
| App Listing | Must Have | Show all installed items by category |
| Search | Must Have | Search by name or bundle identifier |
| Sorting | Must Have | By name, size, last used, install date |
| Filtering | Should Have | Quick filters (unused, large, development) |
| Uninstall | Must Have | Remove app bundle + associated files |
| Batch Operations | Should Have | Select multiple apps for action |

**Acceptance Criteria:**
- [ ] All 8 categories display correct item counts
- [ ] Search returns results within 500ms
- [ ] Uninstall removes all associated files (preferences, caches, support)
- [ ] Protected apps (system, password managers) cannot be uninstalled

---

### 6.7 Notification Rules

**Description:** User-configurable alerts based on system metrics.

**Supported Metrics:**

| Metric | Conditions | Example |
|--------|------------|---------|
| CPU Usage | > 80% for 5 min | "CPU is running hot" |
| Memory Pressure | = Critical | "Memory is critically low" |
| Disk Space | < 10% free | "Disk is almost full" |
| Network | Disconnected | "No network connection" |
| Weather | > 35°C or < 0°C | "Extreme temperature" |

**Requirements:**

| Requirement | Priority | Description |
|-------------|----------|-------------|
| Rule Creation | Must Have | Create custom rules |
| Preset Rules | Must Have | Common rules pre-configured |
| Cooldown | Must Have | Prevent notification spam |
| Trigger History | Should Have | Log of triggered rules |

**Acceptance Criteria:**
- [ ] Rules trigger within 30 seconds of condition met
- [ ] Cooldown prevents duplicate notifications
- [ ] Trigger history shows last 100 entries

---

## 7. Technical Requirements

### System Requirements

| Requirement | Specification |
|-------------|---------------|
| macOS Version | 14.0 (Sonoma) or later |
| Architecture | Apple Silicon (arm64) and Intel (x86_64) |
| Memory | 8 GB minimum, 16 GB recommended |
| Storage | 50 MB for app, variable for cache |

### Permission Requirements

| Permission | Purpose | Required For |
|------------|---------|--------------|
| Full Disk Access | Scan and clean all files | Disk scanning, cleanup, app uninstall |
| Accessibility | Automate system tasks | System optimization, launch services rebuild |
| Notifications | Alert users | Scan completion, low disk space, alerts |
| Location | Weather widget | Current location for weather |
| Location (In Use) | Weather updates | Continuous weather updates |

### Technical Dependencies

| Dependency | Version | Purpose |
|------------|---------|---------|
| SwiftUI | macOS 14+ | User interface framework |
| IOKit | System | Hardware monitoring (CPU, memory, battery, GPU) |
| CoreLocation | System | Location services for weather |
| Sparkle | 2.x | Software update framework |
| Security | System | Keychain access, privileged operations |

### Performance Requirements

| Operation | Target Time | Measured By |
|-----------|-------------|-------------|
| App Launch | < 2 seconds | Time to first frame |
| Smart Scan | < 30 seconds | Total scan time on typical system |
| Deep Clean Scan | < 60 seconds | Category enumeration |
| Widget Update | < 100ms | UI refresh latency |
| Memory Footprint | < 100 MB | Idle state memory usage |

### Security Requirements

- No data collection or telemetry
- All file operations local only
- Privileged helper for root operations (optional)
- Whitelist protection for critical system paths
- Protected apps cannot be uninstalled
- Confirmation required before permanent deletion

---

## 8. User Experience

### Onboarding Flow

**4-Page Wizard:**

| Page | Title | Content |
|------|-------|---------|
| 1 | Welcome | App overview, features, continue button |
| 2 | Permissions | Full Disk Access explanation, grant button, fallback to System Settings |
| 3 | Helper | Privileged Helper explanation, install button |
| 4 | Ready | Summary, launch dashboard button |

**UX Principles:**
- Clear value proposition on each page
- Skip buttons for advanced users
- Non-blocking permission requests
- Clear success/error states

### Safety Guarantees

1. **Preview Before Clean**
   - All cleanup operations show what's being deleted
   - Total size displayed before confirmation
   - Individual items can be deselected

2. **Collector Bin**
   - Deleted items staged in Collector Bin first
   - 7-day retention with restore capability
   - Permanent deletion requires explicit confirmation

3. **Whitelist**
   - User-defined paths protected from cleaning
   - Development directories protected by default
   - System-critical paths always protected

4. **Confirmation Dialogs**
   - All destructive operations require confirmation
   - Clear wording: "This will permanently delete X files"
   - Option to require password for permanent deletion

### Accessibility

- Full VoiceOver support
- Keyboard navigation throughout
- High contrast mode support
- Scalable text sizes
- Reduced motion option

### Theming

- Dark mode (default)
- Light mode
- System-following mode
- Accent color customization

---

## 9. Current State

### Implemented Features

| Feature | Status | Notes |
|---------|--------|-------|
| Dashboard | Complete | Health score, quick actions, stats, recommendations |
| Smart Scan | Complete | 4-stage scan, health score, recommendations |
| Deep Clean | Complete | 10 categories, progress tracking |
| Disk Analysis | Complete | Directory browser, large files |
| Disk Map | Complete | Treemap visualization |
| System Monitoring | Complete | CPU, Memory, Disk, Network, Battery |
| Menu Bar Widgets | Complete | 7 widget types, customization |
| App Inventory | Complete | 8 categories, search, sort, filter |
| App Uninstall | Complete | Bundle + associated files removal |
| Notification Rules | Complete | Custom alerts, presets, history |
| Weather Widget | Complete | Open-Meteo, 7-day forecast |
| Preferences | Complete | Theme, updates, permissions |
| Onboarding | Complete | 4-page wizard |
| Collector Bin | Complete | Staging, restore, permanent delete |

### Partially Implemented

| Feature | Status | Missing |
|---------|--------|---------|
| App Updates | Partial | Sparkle integration complete, batch updates not implemented |
| Cloud Storage Scan | Partial | Detection works, selective cleaning not implemented |
| Network Disk Scan | Partial | Detection works, detailed analysis not implemented |

### Not Yet Implemented

| Feature | Priority | Description |
|---------|----------|-------------|
| Batch Uninstall | Medium | Select multiple apps, remove in one operation |
| Docker/VM Deep Clean | Medium | Container/image management UI |
| Duplicate Finder | Low | Find and merge duplicate files |
| Time Machine Management | Low | Local snapshots cleanup UI |
| iOS Device Backup Manager | Low | iPhone/iPad backup visualization |

### Known Issues

See [GitHub Issues](https://github.com/tw93/Tonic/issues) for current bugs and known limitations.

---

## 10. Success Metrics

### User Acquisition Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| GitHub Stars | 1,000 in 6 months | GitHub repository |
| Downloads | 10,000 in 6 months | GitHub Releases |
| Active Users | 1,000 DAU in 6 months | Anonymous analytics (opt-in) |

### Engagement Metrics

| Metric | Target | Description |
|--------|--------|-------------|
| Smart Scan Completion | > 70% | Users who start a scan complete it |
| Clean Conversion | > 50% | Scans that result in cleanup action |
| Widget Adoption | > 30% of users | Users with at least one menu bar widget |
| Return Rate | > 40% | Users who open app again after 7 days |

### Performance Metrics

| Metric | Target | Description |
|--------|--------|-------------|
| App Launch Time | < 2 seconds | Time to first frame |
| Scan Completion | < 30 seconds | Smart scan on typical system |
| Crash Rate | < 0.1% | Sessions ending in crash |

### User Satisfaction

| Metric | Target | Measurement |
|--------|--------|-------------|
| App Store Rating | 4.5+ stars | Future distribution |
| GitHub Issues | < 10 open bugs | Maintain clean issue tracker |
| Response Time | < 48 hours | Issue response on GitHub |

---

## 11. Freemium Model

> **Note:** The freemium model is planned but not yet implemented. The following describes the intended feature split between Tonic Basic (free) and Tonic Pro (paid). Pricing has not been determined.

### Tiers

| Feature | Basic (Free) | Pro (Paid) |
|---------|--------------|------------|
| **Dashboard** | ✓ | ✓ |
| **Smart Scan** | ✓ | ✓ |
| **System Monitoring** | ✓ | ✓ |
| **Menu Bar Widgets** | 3 widgets | All 7 widgets |
| **App Inventory** | View only | Uninstall + batch operations |
| **Deep Clean** | Basic categories | All 10 categories |
| **Disk Analysis** | Browser only | Browser + Treemap + Large Files |
| **Notification Rules** | Presets only | Custom rules (unlimited) |
| **Weather Widget** | Current temp only | 7-day forecast |
| **App Updates** | - | ✓ |
| **Docker/VM Cleanup** | - | ✓ |
| **Hidden Space Scan** | - | ✓ |
| **Cloud Storage Manager** | - | ✓ |
| **Priority Support** | - | ✓ |

### Free Tier (Tonic Basic)

**Purpose:** Provide core value to all users, demonstrate quality, build user base

**Included Features:**
- Dashboard with health score
- Smart Scan (basic categories)
- System Monitoring (real-time)
- 3 Menu Bar Widgets (CPU, Memory, Disk)
- App Inventory (view only)
- Notification Rules (presets only)
- Preferences (basic settings)

**Limitations:**
- Cannot uninstall apps
- Cannot access development/Docker/Xcode categories
- Cannot create custom notification rules
- Weather widget limited to current temperature
- No treemap visualization

### Pro Tier (Tonic Pro)

**Purpose:** Generate revenue, reward power users, fund continued development

**Additional Features:**
- All 7 Menu Bar Widgets (including GPU, Battery, Weather with forecast)
- Complete Deep Clean (all 10 categories)
- App Uninstall with batch operations
- Disk Treemap visualization
- Custom Notification Rules (unlimited)
- Docker/VM cleanup management
- Hidden space scanner
- Cloud storage manager
- Future: App updater

**Implementation Notes:**
- In-app purchase via Sparkle or App Store
- License key or subscription model (undecided)
- No forced subscription, lifetime option considered
- Pro features remain free during beta period

### Upgrade UX

- Non-intrusive upgrade prompts
- Feature comparison visible before attempting locked feature
- Clear value proposition for Pro
- No degraded experience for free users
- Respectful notification frequency

---

## Appendix A: Glossary

| Term | Definition |
|------|------------|
| Collector Bin | Staging area for items marked for deletion, allows restore |
| Deep Clean | Comprehensive cleanup across multiple system categories |
| Health Score | 0-100 rating of system condition based on multiple factors |
| Menu Bar Widget | Real-time system metric displayed in macOS menu bar |
| Smart Scan | Multi-stage analysis with health scoring and recommendations |
| Treemap | Visualization technique showing hierarchy and size proportionally |
| Whitelist | User-specified paths protected from cleanup operations |

---

## Appendix B: File Structure Reference

```
~/Library/Application Support/Tonic/
├── CollectorBin/
│   └── items.json              # Staged deletion items
├── preferences.json            # User preferences
└── widgetConfigs.json          # Widget configuration

~/Library/Caches/com.tonic.Tonic/
├── Cache.db                    # Disk scan cache
└── WeatherCache/               # Cached weather data

~/Library/Logs/com.tonic.Tonic/
└── app.log                     # Application logs

/Library/PrivilegedHelperTools/
└── com.tonicformac.app.helper  # Privileged helper binary (if installed)
```

---

## Appendix C: API References

| API | Purpose | Documentation |
|-----|---------|---------------|
| IOKit | Hardware monitoring | developer.apple.com/documentation/iokit |
| CoreLocation | Location services | developer.apple.com/documentation/corelocation |
| SwiftUI | UI framework | developer.apple.com/documentation/swiftui |
| Sparkle | Software updates | sparkle-project.org/documentation |
| Open-Meteo | Weather data | open-meteo.com/docs |

---

*Document Version: 1.0*  
*Last Updated: January 2026*  
*Next Review: April 2026*
