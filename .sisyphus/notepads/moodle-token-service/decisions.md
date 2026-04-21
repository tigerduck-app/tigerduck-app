Append-only notes for MoodleTokenService update.

- Kept the actor structure and public API intact while removing duplicate key constants.
- fetchToken now reads AppConstants.KeychainKeys directly so callers no longer pass key strings around.
