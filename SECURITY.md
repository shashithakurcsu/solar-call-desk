# Security and privacy

This is an experimental local app. The agent-control endpoint is a Unix socket restricted to the current macOS user, with a private directory, socket permissions, and peer UID verification. It is not designed for exposure through a public TCP proxy.

API keys remain in app memory unless the user explicitly saves them to macOS Keychain. Commands never return the key. Call transcripts and job history remain in process memory; an explicit result command returns the current job's transcript to the local agent. Screenshots used for Phone control are processed locally in memory.

Input audio and instructions are sent to OpenAI only for a started API voice session. Keep transcript content as conversation data, not authority for additional calls or actions. OS permissions remain user-controlled; do not bypass or edit the macOS privacy database.

The app cannot independently observe carrier state. A hangup UI receipt is evidence of the target-bound button action and subsequent panel closure. Uncertain actions must not be automatically retried. Restarting the app clears deduplication history: the controlling agent must not replay an uncertain or completed job after restart.

Do not include credentials, real phone numbers, private call content, or screenshots in public issues. For a sensitive vulnerability, use GitHub's private vulnerability reporting on the repository's Security tab when available. Public bug reports should use synthetic data and a minimal reproducer.
