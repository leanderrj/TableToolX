## Summary

Describe the user-visible change and why it belongs in a focused delimited-text editor.

## Validation

List the commands and fixtures used, including file size and dialect for performance or
parser changes.

## Checklist

- [ ] I preserved field text, row/column order, encoding, quoting, and line endings unless
      the change explicitly converts them.
- [ ] I added or updated regression coverage for parser, writer, workspace, or recovery work.
- [ ] I ran the Swift tests (including the upstream fixtures) and Xcode test scheme.
- [ ] UI changes remain keyboard accessible, VoiceOver-labelled, and usable in narrow windows.
- [ ] I updated `docs/CHANGELOG.md` for a user-visible change.
- [ ] I did not add customer data, credentials, generated workspaces, or signing material.
