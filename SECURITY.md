# Security Policy

ReviewBar handles forge tokens and runs AI CLIs against code, so security reports are taken seriously.

## Reporting a vulnerability

**Please don't open a public issue.** Use GitHub's [private vulnerability reporting](https://github.com/ganeshmani/reviewbar/security/advisories/new) instead.

Include what you found, how to reproduce it, and the impact you expect. You'll get a reply within a week. Once a fix ships, you'll be credited in the release notes unless you'd rather not be.

## Supported versions

Only the latest release gets security fixes.

## In scope

- Tokens leaking to engines, logs or anywhere outside the Keychain / `glab` / `gh`.
- Anything that posts, approves or writes to a forge without the user's confirmation.
- Prompt injection from MR content that escapes the read-only engine sandbox.
- Ways to make the app execute arbitrary commands.
