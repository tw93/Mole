# fn-1.6 Implement privileged helper tool

## Description
Implement the privileged helper tool using SMJobBless. The helper will be installed during first-run onboarding, not manually via command line.

**Key Actions:**
1. Create XPC service for privileged operations
2. Implement SMJobBless installation API
3. Build helper tool installation status checking
4. Create helper tool removal functionality
5. Implement authorization UI (integrated into onboarding)
6. Add proper error handling for installation failures
7. Code sign helper tool correctly
8. Test installation/removal cycles

**Helper tool capabilities:**
- Remove files from system directories (/Library, /System)
- Clean system caches
- Modify LaunchAgents/LaunchDaemons
- Execute maintenance scripts
- Read system-wide file metadata

**Installation flow (for onboarding integration):**
1. Check if helper is installed
2. If not, prompt user for authorization
3. Use SMJobBless to install helper
4. Verify installation succeeded
5. Show success/error to user

**Security:**
- Validate all XPC requests
- Never execute arbitrary commands
- Use proper code signing requirements
- Implement least-privilege principle

**References:**
- SMJobBless sample: https://developer.apple.com/library/archive/samplecode/EvenBetterAuthorizationSample/
- XPC documentation: https://developer.apple.com/documentation/xpc
## Acceptance
- [ ] Helper tool XPC service functional
- [ ] SMJobBless installation works programmatically
- [ ] Installation status checking works
- [ ] Helper tool removal works cleanly
- [ ] Authorization UI is clear and user-friendly
- [ ] All XPC requests are validated
- [ ] Helper tool code signed properly
- [ ] Installation survives app restart
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
