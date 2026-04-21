Append-only notes for MoodleTokenService update.

- Replacing local Moodle key strings with AppConstants.KeychainKeys keeps auth storage centralized.
- Using AppConstants.moodleBaseURL in the service may require a nonisolated stored property to avoid actor-isolation warnings.
