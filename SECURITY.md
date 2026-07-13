# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in Leise, please report it responsibly.

**Do not open a public issue.** Use GitHub's private vulnerability reporting for the Leise
fork when it is enabled by the repository owner.

Response times depend on the volunteer maintainers of the fork.

## Scope

Leise handles sensitive data including:
- Microphone audio
- AppleScript automation (browser URL detection)

Issues in these areas are especially relevant.

## Security Boundaries

- Support diagnostics are exported as a privacy-safe JSON report and exclude audio payloads and transcription history.

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest release | Yes |
| Current release candidate / preview build | Best effort |
| Older versions | No |
