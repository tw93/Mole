# fn-1.10 Integrate Sparkle update framework

## Description
Integrate the Sparkle framework for automatic updates in the direct-distribution Pro version.

**Key Actions:**
1. Add Sparkle 2.x via Swift Package Manager
2. Configure appcast URL
3. Set up code signing for Sparkle
4. Implement update UI (check for updates, download, install)
5. Add beta channel option
6. Configure delta updates
7. Test update flow end-to-end
8. Handle update failures gracefully

**Note:** App Store Lite version uses StoreKit for updates, not Sparkle.

**References:**
- Sparkle documentation: https://sparkle-project.org/documentation/
- Sparkle SPM: https://github.com/sparkle-project/Sparkle
## Acceptance
- [ ] Sparkle integrated via SPM
- [ ] Update check works from menu
- [ ] Delta updates configured
- [ ] Appcast URL returns valid updates
- [ ] Update download and install works
- [ ] Beta channel option functional
- [ ] Updates properly code signed
- [ ] Graceful failure handling
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
