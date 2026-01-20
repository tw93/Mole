# fn-1.5 Code signing and notarization

## Description
Configure code signing and notarization for direct distribution. This ensures the app and helper tool run properly on macOS without Gatekeeper warnings.

**Key Actions:**
1. Set up code signing certificates (Developer ID)
2. Configure app signing in Xcode build settings
3. Configure helper tool signing (separate bundle ID)
4. Set up entitlements for both app and helper
5. Implement notarization script
6. Add stapling to app bundle
7. Test Gatekeeper flow (double-click to run)
8. Set up automated notarization in CI/CD

**Helper tool signing:**
- Helper must have its own bundle ID (com.pretonic.helper)
- Signed with same Developer ID certificate
- Proper authorization database setup
- SMJobBless requirements configured

**Notarization requirements:**
- App bundle notarized
- Helper tool notarized separately
- Stapled to run offline
- Automatic notarization via xcrun

**References:**
- Apple Notarization Guide: https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution
- SMJobBless: https://developer.apple.com/library/archive/samplecode/EvenBetterAuthorizationSample/
## Acceptance
- [ ] App signs successfully with Developer ID
- [ ] Helper tool signs successfully with separate bundle ID
- [ ] Notarization script completes without errors
- [ ] Stapling works correctly
- [ ] App launches on first double-click without Gatekeeper warning
- [ ] Helper tool installation passes code signature validation
- [ ] CI/CD notarization automated
- [ ] Entitlements properly configured
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
