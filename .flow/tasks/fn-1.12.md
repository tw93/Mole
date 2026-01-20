# fn-1.12 Accessibility and performance optimization

## Description
Implement accessibility features and optimize performance using Instruments profiling.

**Key Actions:**
1. Add VoiceOver support to all views
2. Implement keyboard navigation
3. Add Dynamic Type support
4. Profile with Instruments for bottlenecks
5. Optimize large file scan responsiveness
6. Fix memory leaks
7. Reduce memory usage to <150MB target
8. Test with accessibility inspector

**Performance targets:**
- App launch <2 seconds
- Scan performance >1000 files/sec
- Memory usage <150 MB RAM
- No memory leaks in 10+ minute session

**Accessibility requirements:**
- All elements VoiceOver compatible
- Keyboard navigation works
- Dynamic type respected
- Sufficient color contrast

**References:**
- SwiftUI Performance: https://developer.apple.com/videos/play/wwdc2025/306/
- Accessibility: https://developer.apple.com/accessibility/
## Acceptance
- [ ] VoiceOver navigation works
- [ ] Keyboard navigation complete
- [ ] Dynamic Type supported
- [ ] Instruments profiling completed
- [ ] No memory leaks (10+ minute test)
- [ ] Memory usage <150 MB
- [ ] App launch <2 seconds
- [ ] Accessibility inspector passes
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
