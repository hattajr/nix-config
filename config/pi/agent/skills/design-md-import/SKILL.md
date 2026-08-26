---
name: design-md-import
description: Import a DESIGN.md theme from VoltAgent/awesome-design-md into the current workspace. Use when the user wants a catalog theme by slug such as vercel, linear.app, claude, stripe, or notion saved to root DESIGN.md.
---

# Design MD Import

Use this skill when the user wants to pull a UI design theme from the VoltAgent `awesome-design-md` catalog into the current project.

## Preferred workflow

1. If the user already gave a slug, use the `frontend_get_design` tool with that slug.
2. If the user did not give a slug, ask for it first.
3. Do **not** manually fetch the file with bash, curl, or ad-hoc web steps when this source is the target catalog.
4. After success, tell the user that `DESIGN.md` was written to the workspace root.
5. If the tool reports that the slug does not exist, surface the error clearly and ask the user for a different slug.

## Direct user command

Users can also run this deterministic slash command directly:

```text
/frontend-get-design <slug>
```

That command fetches:

```text
https://raw.githubusercontent.com/VoltAgent/awesome-design-md/refs/heads/main/design-md/<slug>/DESIGN.md
```

and writes it to:

```text
DESIGN.md
```

in the workspace root.

## Notes

- Treat the fetched file as the source of truth unless the user asks you to modify it.
- Useful example slugs: `vercel`, `linear.app`, `claude`, `stripe`, `notion`, `cursor`, `figma`, `supabase`.
- If the user pastes the full raw URL or repo path instead of just a slug, normalize it and still use `frontend_get_design`.
