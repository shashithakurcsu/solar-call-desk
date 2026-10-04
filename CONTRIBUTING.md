# Contributing

Build with a Swift 6+ macOS toolchain and run the offline checks documented in the README. Keep live call tests separate from ordinary builds and CI. The checked-in test examples are synthetic; real call screenshots, phone numbers, transcripts, API keys, signing identities, and local verification records do not belong in a pull request.

Changes to audio buffers should retain bounded memory and callback safety. Changes to call control should preserve per-job action latches, exact-recipient verification, cancellation, stale-event rejection, and the distinction between UI evidence and carrier status. Add a focused synthetic regression for a behavior change.

When proposing support for a new Phone layout, document the tested OS/display configuration and use generated or fully redacted fixtures. Do not weaken target or freshness checks merely to pass an unfamiliar screen. Describe what was verified offline and what still needs an authorized live test.

Contributions are provided under the repository's MIT license. Check licenses before adding dependencies or copied code.
