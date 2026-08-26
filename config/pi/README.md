# .pi

My Pi coding-agent setup, optimized for a plan-first development workflow.

## Command cheatsheet

```text
/start-new-project <name>
/plan-autoloop <slug>
/plan-to-issues <slug>
/build <slug>
/qa-check <slug>
/gen-standup <org> <Nd|Nm>
```

## Development workflow

Used mainly in project workspaces that contain `PLANS/<slug>/...`.

- `/start-new-project <name>` — bootstrap `PLANS/<slug>/draft.md`
- `/plan-autoloop <slug>` — run the draft/plan/review loop until approval or a real user decision is needed
- `/plan-to-issues <slug>` — convert an approved plan into `issues/index.md` plus worker-ready issue files
- `/build <slug>` — implement issue batches and keep execution status up to date
- `/qa-check <slug>` — run behavior/integration QA, append `qa_report.md`, and reopen only affected issues when needed

Typical flow:

```text
/start-new-project my-project
/plan-autoloop my-project
/plan-to-issues my-project
/build my-project
/qa-check my-project
# if QA reopens issues, run /build again and repeat /qa-check until clean
```

Notes:
- First `/qa-check` is broad; later rounds recheck only still-open QA findings.
- Reopened issues are routed through notes like `QA: Q1-03-01` in `issues/index.md`.
- `PLANS/` stays git-ignored; parallel `/build` and `/qa-check` runs use a worktree snapshot hook so planning files are still available to workers.

## Extra tools

- `/gen-standup <org> <Nd|Nm>` — generate a concise written standup plus a plain-language, chatty spoken version for cross-department updates, with a fixed intro/outro and up to 5 sentences per spoken bullet; supports ranges like `7d`, `10d`, `1m` up to `3m`
- `/gh-create-issue [title]` — draft, review, and publish a GitHub issue for the current repo
- `/telegram-notify [on|off|toggle|status|test]` — manage Telegram completion notifications for the parent session

Telegram config lives in `~/.pi/agent/auth.json`:

```json
{
  "telegram": {
    "botToken": "<telegram bot token>",
    "chatId": "<telegram chat id>"
  }
}
```

## Repo layout

- `agent/agents/` — leaf agents (including the Gemini-powered `visual-reviewer`)
- `agent/chains/` — saved workflows
- `agent/extensions/` — custom slash commands and tools
- `agent/scripts/` — helper scripts
- `agent/skills/` — local skills
- `agent/themes/` — local themes
- `agent/intercepted-commands/` — Python and Poetry policy wrappers
- `agent/scripts/` — executable Pi helper scripts
- `agent/messenger/` — static messenger migration data
- `agent/settings.json` — Pi settings and packages
- `agent/scoped-models.json` — versioned scoped-model allowlist
- `agent/keybindings.json` — custom keybindings

## Visual UI reviews

`visual-reviewer` uses `openai-codex/gpt-5.6-sol` at medium thinking for screenshots, images, PDFs, and sampled video frames, with `openai-codex/gpt-5.6-sol:high` as its provider-error fallback. It is intentionally independent from the built-in `reviewer` agent: invoke it explicitly when you want visual feedback. No parallel visual calls are configured.

After applying the dotfiles, reload Pi with `/reload`. To request a visual pass, use `/run visual-reviewer "Review /absolute/path/screenshot.png for hierarchy, contrast, and mobile issues at 390px."` and include absolute media paths plus the review requirements and viewport context. The normal `/run reviewer ...` command remains the built-in code reviewer and does not call Gemini automatically.

## Setup

Use Node.js `22.22.3` (or newer `22.x`). `.nvmrc` is pinned.

Home Manager deploys the static configuration and custom agents, chains,
extensions, skills, scripts, themes, and command wrappers into `~/.pi`.
Install Pi separately, then run it normally:

```bash
npm install -g @earendil-works/pi-coding-agent
pi
# run /login if needed
```

Credentials remain runtime state in `~/.pi/agent/auth.json` and are not managed
by Home Manager.

If packages are missing:

```bash
pi install npm:pi-subagents
pi install npm:pi-web-access
pi install npm:@juicesharp/rpiv-ask-user-question
```

Pi packages and extensions can be updated through Pi itself:

```bash
pi update --self
pi update --extensions
```

## Notes

- Run `/reload` after changing extensions, settings, keybindings, or local auth/config.
- `agent/scoped-models.json` is the source-of-truth list for `/scoped-models` and is committed with this dotfiles repo.
- The managed `~/.local/bin/pi` wrapper restores that list before each Pi launch because Pi can remove `enabledModels` when its selector saves an all-models selection.
- External editor is bound to `Ctrl+Shift+G` via `agent/keybindings.json`.
- Secrets and local runtime state are ignored by `.gitignore`.
- This repo is my Pi setup, not a standalone app project.
