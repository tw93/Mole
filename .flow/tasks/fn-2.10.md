# fn-2.10 Create notification rules engine

## Description

Create a rules engine for triggering notifications based on system and weather conditions.

**Files to create:**
- `Tonic/Services/NotificationRuleEngine.swift` - Rules evaluator
- `Tonic/Models/NotificationRule.swift` - Rule data model
- `Tonic/Views/NotificationRulesView.swift` - Configuration UI

**Rule model:**
```swift
struct NotificationRule: Identifiable, Codable {
    let id: UUID
    var name: String
    var isEnabled: Bool
    var metric: MetricType  // cpu, memory, disk, network, weather
    var condition: Condition // greaterThan, lessThan, equals
    var threshold: Double
    var cooldown: TimeInterval  // Min time between alerts
    var lastTriggered: Date?
}

enum MetricType: String, CaseIterable {
    case cpuUsage, memoryPressure, diskSpace, networkDown, weatherTemp
}
```

**RuleEngine:**
- Evaluate rules on each data update
- Respect cooldown periods
- Trigger UNUserNotification when rule matches
- Store triggered timestamps

**Configuration UI:**
- List of all rules
- Add/edit/delete rule dialog
- Enable/disable toggle per rule
- Threshold slider input

## Acceptance

- [ ] NotificationRule model with all properties
- [ ] RuleEngine evaluates on WidgetDataManager updates
- [ ] Cooldown period prevents spam
- [ ] UNUserNotificationCenter integration
- [ ] Configuration UI in Settings
- [ ] Rules persist via UserDefaults
- [ ] Test notification button per rule

## Done summary
Created notification rules engine with configurable thresholds. NotificationRule model with metric type, condition, threshold, and cooldown. RuleEngine evaluates on WidgetDataManager updates with cooldown to prevent spam. UNUserNotificationCenter integration for notifications. Configuration UI in Settings with add/edit/delete rules. Rules persist via UserDefaults. Test notification button per rule.
## Evidence
- Commits:
- Tests:
- PRs: