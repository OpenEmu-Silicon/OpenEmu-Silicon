# Security Policy

## Supported Versions

Only the latest release receives security fixes. Older versions are not patched.

| Version | Supported |
|---------|-----------|
| 1.4.0 (latest) | ✅ |
| < 1.4.0 | ❌ |

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Report vulnerabilities privately using [GitHub's private vulnerability reporting](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/security/advisories/new). This keeps the details confidential until a fix is available.

Include as much of the following as you can:

- A description of the vulnerability and its potential impact
- Steps to reproduce or a proof-of-concept
- Affected version(s)
- Any suggested fix, if you have one

## Response Process

- You will receive acknowledgement within **7 days**
- If the report is confirmed, a fix will be prioritised based on severity
- You will be credited in the release notes unless you prefer to remain anonymous

## Scope

This project is a macOS desktop emulator. The primary attack surface relevant to security reports:

- **Google Drive OAuth integration** — token storage, scope handling, redirect URI
- **ROM/save file parsing** — malformed files that could cause unexpected behaviour
- **Core plugins** — bundled emulation cores that process untrusted input (ROM data)

Out of scope: vulnerabilities in upstream emulation cores (report those to the respective upstream projects), or issues requiring physical access to the machine.

## Privacy Policy

For information on how the app handles user data, see the [Privacy Policy](docs/privacy-policy.md).
