//
//  NotificationRulesView.swift
//  Tonic
//
//  Notification rules configuration UI
//  Task ID: fn-2.10
//

import SwiftUI

// MARK: - Notification Rules View

/// Configuration UI for notification rules
struct NotificationRulesView: View {

    @State private var engine = NotificationRuleEngine.shared
    @State private var showingAddRule = false
    @State private var editingRule: NotificationRule?

    init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Rules list
            if engine.rules.isEmpty {
                emptyState
            } else {
                rulesList
            }

            Divider()

            // Footer
            footer
        }
        .frame(width: 500, height: 400)
        .sheet(isPresented: $showingAddRule) {
            AddRuleView(rule: editingRule) { rule in
                if let existing = editingRule {
                    engine.updateRule(rule)
                } else {
                    engine.addRule(rule)
                }
                editingRule = nil
            }
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "bell.badge.fill")
                    .foregroundColor(TonicColors.accent)

                Text("Notification Rules")
                    .font(.headline)
            }

            Spacer()

            Button {
                engine.resetToPresets()
            } label: {
                Text("Reset to Presets")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bell.slash")
                .font(.system(size: 40))
                .foregroundColor(.secondary)

            Text("No notification rules configured")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("Add rules to get notified about system events")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rulesList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(engine.rules) { rule in
                    RuleRow(rule: rule)
                        .onTapGesture {
                            editingRule = rule
                            showingAddRule = true
                        }
                }
            }
            .padding()
        }
    }

    private var footer: some View {
        HStack {
            Text("Active Rules: \(engine.rules.filter { $0.isEnabled }.count)")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            Button {
                editingRule = nil
                showingAddRule = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                    Text("Add Rule")
                }
                .font(.subheadline)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Rule Row

private struct RuleRow: View {
    let rule: NotificationRule

    var body: some View {
        HStack(spacing: 12) {
            // Toggle
            Toggle("", isOn: .constant(rule.isEnabled))
                .toggleStyle(.switch)
                .disabled(true)

            // Icon
            Image(systemName: rule.metric.icon)
                .foregroundColor(rule.isEnabled ? TonicColors.accent : .secondary)
                .frame(width: 20)

            // Rule details
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.name)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(ruleDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Cooldown indicator
            if rule.isInCooldown {
                Image(systemName: "clock.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            // Status indicator
            Circle()
                .fill(rule.isEnabled ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private var ruleDescription: String {
        "\(rule.metric.displayName) \(rule.condition.symbol) \(Int(rule.threshold))\(rule.metric.unit)"
    }
}

// MARK: - Add/Edit Rule View

private struct AddRuleView: View {
    let rule: NotificationRule?
    let onSave: (NotificationRule) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var metric: MetricType = .cpuUsage
    @State private var condition: Condition = .greaterThan
    @State private var threshold: Double = 80
    @State private var cooldownMinutes: Double = 30

    init(rule: NotificationRule? = nil, onSave: @escaping (NotificationRule) -> Void) {
        self.rule = rule
        self.onSave = onSave

        if let rule = rule {
            _name = State(initialValue: rule.name)
            _metric = State(initialValue: rule.metric)
            _condition = State(initialValue: rule.condition)
            _threshold = State(initialValue: rule.threshold)
            _cooldownMinutes = State(initialValue: Double(rule.cooldownMinutes))
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            // Header
            Text(rule == nil ? "Add Notification Rule" : "Edit Rule")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Rule name
            VStack(alignment: .leading, spacing: 8) {
                Text("Rule Name")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                TextField("e.g., High CPU Alert", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            // Metric selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Metric to Monitor")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Picker("Metric", selection: $metric) {
                    ForEach(MetricType.allCases, id: \.self) { type in
                        HStack {
                            Image(systemName: type.icon)
                            Text(type.displayName)
                        }
                        .tag(type)
                    }
                }
                .pickerStyle(.menu)
            }

            // Condition
            VStack(alignment: .leading, spacing: 8) {
                Text("Condition")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Picker("Condition", selection: $condition) {
                    ForEach(Condition.allCases, id: \.self) { cond in
                        Text(cond.displayName).tag(cond)
                    }
                }
                .pickerStyle(.segmented)
            }

            // Threshold
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Threshold")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Spacer()

                    Text("\(Int(threshold))\(metric.unit)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }

                Slider(value: $threshold, in: metric.minThreshold...metric.maxThreshold, step: metric.step)
            }

            // Cooldown
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Cooldown Period")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Spacer()

                    Text("\(Int(cooldownMinutes)) min")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Slider(value: $cooldownMinutes, in: 5...120, step: 5)
            }

            Spacer()

            // Actions
            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("Save Rule") {
                    saveRule()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(name.isEmpty)
            }
        }
        .padding()
        .frame(width: 400, height: 450)
    }

    private func saveRule() {
        let newRule = NotificationRule(
            id: rule?.id ?? UUID(),
            name: name,
            isEnabled: rule?.isEnabled ?? true,
            metric: metric,
            condition: condition,
            threshold: threshold,
            cooldownMinutes: Int(cooldownMinutes),
            lastTriggered: rule?.lastTriggered
        )

        onSave(newRule)
        dismiss()
    }
}

// MARK: - Preview

#Preview("Notification Rules") {
    NotificationRulesView()
        .frame(width: 500, height: 400)
}
