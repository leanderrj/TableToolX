# Security policy

## Supported versions

Until the first Table Tool X release, security fixes are applied to `main`. After v1.3.0, the
latest stable release and `main` receive security fixes.

## Reporting a vulnerability

Please use GitHub's [private vulnerability reporting](https://github.com/leanderrj/TableToolX/security/advisories/new)
instead of opening a public issue. Include the affected macOS and Table Tool X versions,
the input or workflow that triggers the issue, its impact, and reproduction steps.

CSV files may contain confidential data. Remove or replace real records before attaching a
sample. Do not include Apple signing credentials, Sparkle private keys, passwords, or tokens.

The maintainer will acknowledge a report within seven days and coordinate disclosure after a
fix is available. Data-integrity bugs that silently alter fields, row order, quoting, encoding,
or line endings are also appropriate for private reporting when exploitation or confidential
data exposure may be involved.

## Data handling

Table Tool X keeps document workspaces locally under its Application Support container,
excludes them from backup, and deletes clean workspaces. Unsaved recovery workspaces expire
after seven days. Recovery manifests retain a security-scoped bookmark only when needed to
restore access to the document the user opened. The application does not upload documents,
analytics, or crash reports.
