# fn-3.1 Fix CPU memory deallocation bug

## Description
TBD

## Acceptance
- [ ] TBD

## Done summary
Fixed CPU memory deallocation to use MemoryLayout<integer_t>.size instead of MemoryLayout<Int>.size, preventing potential crashes from incorrect deallocation size on arm64 where integer_t is Int32 but Int is 64-bit.
## Evidence
- Commits:
- Tests:
- PRs: