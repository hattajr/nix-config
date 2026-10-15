---
name: ui-review
description: Capture screenshots of a running web UI with playwright-cli and review them for visual, layout, responsive, and accessibility problems. Use when asked to check, screenshot, or review how a page looks, after changing frontend code, or to verify a UI fix in a real browser.
---

Use the `playwright-cli` skill for command details. This skill is the capture-and-review loop on top of it.

## 1. Agree on the target

Find the URL from the request, the project's run instructions, or a server you already started. If no server is running, start the project's dev server in the background first; never review a stale build. Ask only when the URL, the login, or the pages to cover cannot be inferred.

## 2. Capture

Keep evidence outside the repository and use a named session so parallel agents do not share a browser:

```bash
out="${TMPDIR:-/tmp}/ui-review/$(basename "$PWD")-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
export PLAYWRIGHT_CLI_SESSION="ui-review-$(basename "$PWD")"

playwright-cli open "$url"
playwright-cli resize 1440 900
playwright-cli screenshot --full-page --filename="$out/desktop-light.png"
playwright-cli resize 390 844
playwright-cli screenshot --full-page --filename="$out/mobile-light.png"
playwright-cli set-color-scheme dark
playwright-cli screenshot --full-page --filename="$out/mobile-dark.png"
playwright-cli console warning > "$out/console.txt"
playwright-cli close
```

Adjust the matrix to the request: drop dark mode when the app has no theme, add a tablet width (`768 1024`) for layout work, and capture interaction states (open menu, validation error, empty list, loading) by driving the page with `snapshot`, `click`, and `fill` before taking `screenshot <ref>` of the relevant element. Name each file after its page, viewport, and state.

Always `close` the session, even after a failure.

## 3. Review

- **Pi with a `subagent` tool and a `visual-reviewer` agent:** delegate one review pass with the image paths, the console log, the URL, and what changed or what the user is worried about. Relay its findings rather than reviewing twice.
- **Otherwise (Claude Code, or no reviewer):** read each PNG yourself with the file-read tool. Never review from file names or snapshot YAML alone.

Judge what is visible: hierarchy, spacing, alignment, overflow and clipping, text that wraps badly, contrast, focus visibility, target size, broken images, unstyled content, and differences between viewports and themes. Treat console errors as findings. Separate what you can see from what you infer.

## 4. Report

```text
## UI review: <url>
- Verdict: one sentence
- Critical / High / Medium: findings with file name, the visible evidence, and a concrete fix (or "None")
- Positive: what to keep
- Evidence: <out directory>
- Not covered: viewports, states, or pages not captured
```

When you then fix code, re-capture only the affected screenshots and confirm the fix visually before reporting it done.
