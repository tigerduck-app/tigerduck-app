# Commit Format Specification

Pattern: type(scope): short description

Allowed types: feat, fix, refactor, chore
Example: feat(MoodleAuth): add MoodleTokenService with actor-based token exchange

Rules:
- NO Co-Authored-By lines
- GPG signed (commit.gpgsign=true, key D4FDC6CA456096D4)
- Body: bullet points with "- " prefix
- Refs: #issue at end of body
- Multiple commits per feature (checkpoint style)

## Observed Recent Commits (conforming examples)
- fix(AppLogger): add token scrubbing to performance span beforeSend hook
- fix(AuthService, SSOLoginService): improve error handling for login failures
- fix(SecureStore): improve legacy value migration handling
- chore(project.pbxproj): add exceptions for markdown files in TigerDuck target
- refactor(VisualStylePolicy): centralize primary/secondary text colors

All recent commits carry valid GPG signatures (git log --format='%G?' → G).
