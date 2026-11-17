# Changelog

## 1.0.6 (2026-11-16)

First open-source release.

- Signed with a Developer ID and notarized by Apple.
- Fix: the app could hang ("not responding") when finding the `claude` CLI needed a slow login shell. Shell lookups now time out after 15 seconds and run off the main thread.
- Group the inbox by repository.
- "Dismiss all" for MRs that were discovered but never reviewed.
- Tab badges for new items.
- "Copy fix prompt" after posting, so the author can address threads in their own Claude Code session.
- "Not sensitive, allow posting" override for findings flagged as security.
- Markdown in summaries and findings; shorter summaries.
- Right-click the menu bar icon for Settings and Quit.
- Paste (⌘V) works in text fields.
- Fix: popover jumping to the left edge of the screen.
- Auto-review only queues new, open, non-draft MRs, never the backlog that exists when you connect.
- GitLab: send glab OAuth tokens correctly and refresh them when they expire.
