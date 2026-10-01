---
name: setup-daisyui-tailwind-fastapi
description: "Set up Tailwind CSS v4 + daisyUI v5 inside a Python/FastAPI project. Use when starting a new FastAPI app, adding styling to an existing one, or wiring the Tailwind CLI build into FastAPI's static file serving. Covers install, CSS entry file, build script, watch mode, FastAPI static mount, Jinja2 templates, theme switching, and dev workflow. No bundler, no React, no Vite."
---

# Setup: Tailwind CSS v4 + daisyUI v5 + FastAPI

Minimal setup: FastAPI serves Jinja2 templates and a compiled Tailwind + daisyUI stylesheet, built with the npm-based Tailwind CLI (`@tailwindcss/cli`). No bundler.

## When to Use

- New FastAPI project needing UI
- Adding Tailwind + daisyUI to an existing FastAPI app
- Wiring Tailwind CLI build into FastAPI static files

## Stack

- FastAPI + Jinja2 (Python deps via `uv`)
- Tailwind CSS v4 via `@tailwindcss/cli` (Node only at build time)
- daisyUI v5 (Tailwind plugin)
- HTMX + Alpine.js via CDN

## Companion Skills

- Visual direction / typography / theme choice → `frontend-design`
- HTMX/Alpine interaction patterns → `htmx-alpine`

## File Locations

- `styles/app.css` — Tailwind + daisyUI entry (committed)
- `app/templates/` — Jinja2 templates
- `app/static/css/output.css` — build artifact (gitignored)
- `app/static/js/` — any vanilla JS
- `app/main.py` — FastAPI app, mounts `/static` and Jinja2
- `package.json` — Node build scripts (committed)
- `pyproject.toml` — Python deps

## 1. Install

```bash
npm init -y
npm install -D tailwindcss@latest @tailwindcss/cli@latest daisyui@latest
uv add fastapi jinja2 "uvicorn[standard]"
```

## 2. CSS entry — `styles/app.css`

```css
@import "tailwindcss";
@source "../app/templates/**/*.html";
@source "../app/**/*.py";
@plugin "daisyui" {
  themes: light --default, dark --prefersdark;
}
```

No `tailwind.config.js` needed in v4. Add more `@source` lines if class names appear elsewhere.

## 3. Build scripts — `package.json`

```json
{
  "scripts": {
    "build:css": "npx @tailwindcss/cli -i styles/app.css -o app/static/css/output.css --minify",
    "watch:css": "npx @tailwindcss/cli -i styles/app.css -o app/static/css/output.css --watch"
  }
}
```

## 4. FastAPI wiring

In `app/main.py`, mount `StaticFiles` at `/static` pointing to `app/static`, and create a `Jinja2Templates` instance pointing to `app/templates`.

## 5. Base template — `app/templates/base.html`

Link the built CSS and load HTMX + Alpine from CDN, set `data-theme` on `<html>`, include `[x-cloak]{display:none!important}` to prevent FOUC.

## 6. Dev workflow

Two terminals: `npm run watch:css` and `uv run uvicorn app.main:app --reload`. Optional: combine with `honcho` / a `Procfile`.

## 7. `.gitignore`

Ignore `node_modules/`, `app/static/css/output.css`, `.venv/`, `__pycache__/`.

## 8. Production

Run `npm ci && npm run build:css` in your build stage, then run `uv run uvicorn ...`. For Docker, do the CSS build in a Node stage and copy `output.css` into the Python image so runtime doesn't need Node.

## 9. Theme switching

Set `data-theme` on `<html>` server-side (from cookie/user pref) to avoid FOUC. Client-side switch: bind a `<select>` with Alpine to update `document.documentElement.dataset.theme`.

## Common Pitfalls

| Pitfall | Fix |
|---|---|
| Classes don't apply | Missing `@source` path or templates outside scanned glob |
| daisyUI classes missing | `@plugin "daisyui"` not in `app.css` |
| 404 on `/static/css/output.css` | `StaticFiles` mount mismatch or build hasn't run |
| CSS not updating in dev | Not running `npm run watch:css` |
| FOUC on theme switch | Set `data-theme` server-side on `<html>` |
| Class names in `.py` strings ignored | Add `@source "../app/**/*.py";` |

## Authoritative Resources

- [daisyUI install](https://daisyui.com/docs/install/) · [daisyUI CLI](https://daisyui.com/docs/install/cli/)
- [Tailwind CSS v4](https://tailwindcss.com/docs/installation)
- [FastAPI templates](https://fastapi.tiangolo.com/advanced/templates/)
- [HTMX](https://htmx.org/docs/) · [Alpine.js](https://alpinejs.dev/)
