# Contributing

Contributions are welcome. Before opening a pull request:

1. Keep user data as text unless a comparison operation explicitly requests another type.
2. Do not add network services, telemetry, or runtime dependencies without prior discussion.
3. Add a regression test for parser, writer, workspace, or data-fidelity changes.
4. Run `swift test`, `actionlint`, and the Xcode test scheme generated with `xcodegen generate`.
5. Keep UI work keyboard accessible and label controls for VoiceOver.

Use GitHub issues for bug reports and feature proposals. Include a minimal, anonymized fixture
when reporting a CSV parsing problem and state its encoding and expected dialect if known.
