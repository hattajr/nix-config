---
name: handoff
description: Compact the current conversation into a handoff document for another agent to pick up.
argument-hint: "[local|remote] [What will the next session be used for?]"
disable-model-invocation: true
---

## Destination argument

If the first argument is `local` or `remote`, consume it as the destination selector. Treat only the remaining arguments as the description of what the next session will focus on. If neither selector is present, keep the original behavior: local storage, with all arguments describing the next session's focus.

- `local`: Create a new handoff document in the temporary directory of the user's OS, or update an existing handoff there when its path is supplied or already known for this work. Resolve the OS temporary directory rather than assuming `/tmp`; never save in the current workspace.
- `remote`: Instead of saving to the OS temporary directory, create a GitHub issue in the current workspace's repository with `gh issue create`, or update an existing handoff issue with `gh issue edit` when its number or URL is supplied or already known for this work. Use the handoff document as the issue body. Follow any configured approval requirements for GitHub writes.

Only update a handoff clearly identified for this work; do not overwrite an unrelated issue or file. Return the saved file's absolute path or the GitHub issue URL so the next agent can find it.

## Original handoff instructions

Write a handoff document summarising the current conversation so a fresh agent can continue the work. Save to the temporary directory of the user's OS - not the current workspace.

Include a "suggested skills" section in the document, naming which skills the next agent should call the Skill tool for.

Do not duplicate content already captured in other artifacts (specs, plans, ADRs, issues, commits, diffs). Reference them by path or URL instead.

Redact any sensitive information, such as API keys, passwords, or personally identifiable information.

If the user passed arguments, treat them as a description of what the next session will focus on and tailor the doc accordingly.
