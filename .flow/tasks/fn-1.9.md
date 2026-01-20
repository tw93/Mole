# fn-1.9 Port system optimization to Swift

## Description
Port the system optimization module from Bash to Swift. This runs maintenance tasks and system health checks.

**Key Actions:**
1. Study `lib/optimize/tasks.sh:104-779`
2. Create Swift optimization orchestrator
3. Implement maintenance task execution via helper
4. Add health check UI
5. Create scheduled maintenance option
6. Implement Time Machine integration checks
7. Add system update detection
8. Create optimization results summary

**Reuse from codebase:**
- `lib/optimize/tasks.sh:104-779` - All optimization functions
- `lib/optimize/maintenance.sh` - System maintenance
- `lib/check/all.sh` - System health checks
- `lib/check/health_json.sh` - Health data structure

**Safety:**
- Check Time Machine status before operations
- Never run during active backup
- Show what each optimization does
- Allow user to skip specific tasks

**References:**
- `lib/optimize/tasks.sh:104-779` - All optimization functions
- `lib/check/all.sh` - Health check patterns
## Acceptance
- [ ] All `lib/optimize/tasks.sh` functions ported
- [ ] Health checks run and display results
- [ ] Time Machine status checked before operations
- [ ] System update detection works
- [ ] Maintenance tasks execute via helper
- [ ] Optimization results summarized
- [ ] User can select/deselect specific tasks
- [ ] Progress shown during optimization
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
