# fn-1.11 Onboarding with helper install and permissions

## Description
Implement comprehensive first-run onboarding that installs the privileged helper tool and requests all necessary permissions. This is the user's first experience with the app.

**Key Actions:**
1. **Create onboarding wizard with multiple screens**
2. **Welcome screen** - App introduction, value proposition
3. **Permission overview** - Explain what's needed and why
4. **Helper tool installation** - Integrate fn-1.6 installation flow
   - Show clear explanation of what helper does
   - Trigger SMJobBless installation
   - Show progress spinner
   - Handle success/failure gracefully
5. **Full Disk Access request**
   - Explain why it's needed (deep cleaning, system scan)
   - Provide direct link to System Settings
   - Pause onboarding until granted
   - Detect when permission is granted
6. **Accessibility permission request** (optional features)
7. **Feature tour** - Brief walkthrough of main features
8. **Completion screen** - All features ready, go to dashboard

**Permission detection:**
- Check Full Disk Access status
- Check Accessibility status
- Check helper tool installed status
- Show which permissions are still needed

**UX considerations:**
- Onboarding completes in <60 seconds
- Clear progress indication
- Can skip optional permissions
- Can retry failed helper installation
- Can re-run onboarding from Settings

**Error handling:**
- Helper install fails → show retry option, explain what features won't work
- User denies permissions → show what's limited, offer to open Settings later
- Network issues → defer non-critical setup

**References:**
- Apple HIG Onboarding: https://developer.apple.com/design/human-interface-guidelines/onboarding
- TCC permissions: https://developer.apple.com/documentation/security/preventing_unauthorized_access_to_protected_resources
## Acceptance
- [ ] Onboarding wizard implemented with SwiftUI
- [ ] Welcome screen displays app value clearly
- [ ] Helper tool installation integrated and works
- [ ] Full Disk Access permission requested with System Settings link
- [ ] Permission detection works (can tell if granted/denied)
- [ ] Feature tour highlights main features
- [ ] Onboarding completes in <60 seconds
- [ ] Failed helper install shows clear error and retry
- [ ] User can skip optional permissions
- [ ] Onboarding can be re-run from Settings
- [ ] All features unlocked after successful onboarding
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
