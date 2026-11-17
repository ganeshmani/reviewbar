---
target: "review https://reviewbar.vercel.app/#download"
total_score: 24
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 3
target_identity: "file:/Users/ganesh/Desktop/my-products/ReviewBar/website/index.html"
target_fingerprint: "sha256:b00b31075778d3cce1aac4929a3f7ba3978a38b7af52fd7ac1d4721b8eb9238a"
target_path: /Users/ganesh/Desktop/my-products/ReviewBar/website/index.html
timestamp: 2026-11-17T06-20-34Z
slug: website-index-html
---
# Critique: Install section (#download), website/index.html
Method: dual-agent (A: design review, B: detector + browser)

## Heuristics 24/40
1 Status 2 (copy feedback visual-only, silent failure; no version/date) | 2 Real world 3 | 3 Control 3 (.dmg links to releases page) | 4 Consistency 2 (Install/Install with Homebrew/Install ReviewBar/Download; h2 doesn't say install) | 5 Error prevention 2 (no no-Homebrew path; no prereq links) | 6 Recognition 3 | 7 Flexibility 3 | 8 Minimalist 3 ($0 + empty reqs space) | 9 Error recovery 1 (Gatekeeper note is faint 12px footnote) | 10 Help 2 (no install/first-launch FAQ)

## Specificity
Authored tokens/copy, template layout ($0 pricing card + spec sheet). Detector: 3 warnings, none in #download (all-caps hero eyebrow = false positive; 11px queue label + 10px "Blocker" in app mock). Overlay failed: Chrome Private Network Access blocked localhost detect.js from https origin.

## Priority issues
- [P1] Primary action under-weighted, Install hand-off broken: rename h2 "Install ReviewBar", demote $0, key-styled 36px "Copy command", unify labels. clarify + layout
- [P1] Not-notarized warning faint (3.30/3.25:1), reads DMG-only: make it step 3 "First launch" in sans 14px --rb-ink, add why-it's-safe line + FAQ entry; better: notarize. clarify + harden
- [P1] Copy button: no fallback/catch, aria-label hides "Copied", no aria-live, no focus-visible. harden
- [P2] Copy button inside overflow-x pre scrolls away at ~375px and ~1000-1100px; move it out, join commands with &&. adapt
- [P2] Prereqs not linked; direct DMG link with version/size; reqs labels --rb-faint 3.45/3.01:1 -> --rb-mute. clarify

## Personas
Skeptic: no version/date/checksum/cask link. No-Homebrew first-timer: DMG equal weight to source, lands on releases page; misses Gatekeeper note. A11y: contrast fails, Copied not announced, sideways-scrolling code.

## Minor
Empty space in .reqs at 1440; "Free and open source" x3; duplicate GitHub buttons; dark .cmd barely distinct; closing CTA jumps back up.
