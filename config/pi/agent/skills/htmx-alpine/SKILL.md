---
name: htmx-alpine
description: >
  Use when building, reviewing, or debugging server-driven web applications with HTMX and Alpine.js.
  Trigger this skill whenever the user mentions hx-post, hx-get, hx-target, hx-swap, x-data, x-model,
  hypermedia, server-driven HTML, or partial page updates. Also trigger when a user is about to (or has
  already) reached for fetch(), DOM manipulation, or JavaScript state management in a context where
  HTMX + Alpine.js would be more appropriate. Trigger even if the user doesn't name the libraries
  explicitly — e.g. "submit a form without a full page reload", "show a spinner while waiting for the
  server", "keep a counter in sync with my backend". When in doubt, trigger — this skill covers the
  full interaction model, antipatterns, and decision rules for the stack.
---

# HTMX + Alpine.js

Build server-driven web applications where the server returns HTML and the client manages UI state.
HTMX handles all server communication. Alpine.js handles client-side state that doesn't need server
round-trips.

**Core principle:** The server is the source of truth. The client is a thin rendering layer.

---

## When NOT to use this stack

Stop and consider a full JS framework (React, Vue, Svelte) if the UI requires:

- Rich drag-and-drop interactions (e.g. Kanban boards, sortable trees)
- Complex real-time collaborative editing (e.g. shared rich-text documents)
- Highly stateful, offline-capable applications (e.g. local-first apps)
- Canvas/WebGL rendering driven by frequent client-side data updates
- A component ecosystem (e.g. data grids, date pickers) that assumes React/Vue

If any of the above apply, say so and recommend the appropriate framework rather than forcing HTMX + Alpine.

---

## Quick Reference — What to Load

| If you're… | Load |
|---|---|
| Using `hx-get`, `hx-post`, `hx-target`, `hx-swap` | `references/htmx-requests.md` |
| Managing UI state with `x-data`, `x-model` | `references/alpine-state.md` |
| Coordinating HTMX and Alpine together | `references/integration.md` |
| Building confirm dialogs, multi-step forms | `references/integration.md` |
| Adding loading spinners, error handling | `references/feedback-patterns.md` |
| Using SSE or WebSocket extensions | `references/realtime.md` |
| Concerned about focus, ARIA, screen readers | `references/accessibility.md` |
| Using Axum + Askama for handlers | `references/frameworks/rust-axum.md` |

---

## When to Use Each Tool

| Need | Use | Not |
|---|---|---|
| Submit form to server | HTMX `hx-post` | `fetch()` |
| Update page section | HTMX `hx-target` + `hx-swap` | JS DOM manipulation |
| Show/hide element | Alpine `x-show` | `classList.toggle()` |
| Track form field state | Alpine `x-data` + `x-model` | JS variables |
| Loading indicator | HTMX `hx-indicator` or Alpine `:disabled` | JS event handlers |
| Multi-step flow | Alpine (in-step UI) + HTMX (each step submission) | JS state machine |
| Real-time updates | HTMX SSE/WS extension | `new WebSocket(...)` |
| Conditional rendering | Alpine `x-if` / `x-show` | `innerHTML` toggling |
| URL updates on swap | `hx-push-url="true"` | `history.pushState()` |

---

## Core Principles

**Server is Source of Truth.** Business logic and data validation belong on the server. The server
returns HTML fragments — not JSON. The client renders what it receives.

**HTMX for server round-trips.** Any operation that reads or writes server data uses `hx-*` attributes.
Don't reach for `fetch()`.

**Alpine for ephemeral UI state.** `x-*` attributes manage state that is purely visual and not
persisted — dropdown open/closed, character counts, tab selection. If the user refreshes and the
state is gone, that's correct behavior. Alpine state must never shadow or cache server data.

**Progressive enhancement.** The page should be usable without JavaScript. HTMX and Alpine enhance
the experience but aren't required for basic functionality.

**Accessibility is not optional.** Dynamic content requires focus management, ARIA live regions, and
keyboard navigation. See `references/accessibility.md`.

---

## STOP — Anti-Rationalization Table

Before writing code that matches any pattern below, pause and reconsider.

| You're about to… | Common rationalization | What to do instead |
|---|---|---|
| Use `fetch()` for a form submission | "I know fetch better" / "I need more control" | Use `hx-post`. HTMX handles errors, indicators, and swap — things you'll forget. Load `references/htmx-requests.md`. |
| Store server data in Alpine `x-data` | "It's faster than round-tripping" / "Just caching" | Alpine state is UI-only. Server data lives on the server. Load `references/alpine-state.md`. |
| Manipulate the DOM with JavaScript | "Just a quick classList change" | Use `hx-swap` for server-driven updates, Alpine `x-show`/`x-bind` for client-driven visibility. |
| Skip focus management after a swap | "Users can click" / "Ship it" | Keyboard and screen-reader users can't click. Load `references/accessibility.md`. |
| Build a multi-step wizard with Alpine-only state | "The steps are just UI" | Each step submission must persist to the server. Use HTMX per step, Alpine for in-step UI only. |
| Skip loading indicators | "It's fast enough" | It's not always fast. Always add `hx-indicator`. Load `references/feedback-patterns.md`. |
| Use `innerHTML` in JavaScript | "Just this once" | Use `hx-swap`. If truly necessary client-side, use Alpine `x-html` with sanitized content only. |
| Send JSON over WebSocket and build DOM client-side | "More flexible" / "Structured data is easier" | The server renders HTML fragments and sends them directly via `htmx-ws` with OOB swaps. Load `references/realtime.md`. |
| Use `hx-boost` site-wide | "Easy wins on every link" | `hx-boost` breaks non-GET forms and some anchor behaviors silently. Apply it deliberately and test. |
| Update content without updating the URL | "It's just a partial update" | Use `hx-push-url="true"` so the back button and bookmarks work correctly. |
| Use polling (`hx-trigger="every 2s"`) for live data | "SSE seems complicated" | SSE is one attribute and a streaming endpoint. Polling wastes connections. Load `references/realtime.md`. |
| Use `x-teleport` (e.g. for modals) without focus management | "The modal looks fine" | Teleporting an element doesn't move focus. Implement a focus trap or use a library. Load `references/accessibility.md`. |

---

## Common Runtime Symptoms and Fixes

| Symptom | Cause | Fix |
|---|---|---|
| Flash of unstyled/visible Alpine content on load | Missing `x-cloak` | Add `[x-cloak] { display: none !important; }` to your CSS |
| Back button doesn't restore content | Missing `hx-push-url` | Add `hx-push-url="true"` to swapping elements |
| Screen reader doesn't announce updates | No ARIA live region | Add `aria-live="polite"` to the swap target container |
| Modal traps nothing; Tab escapes | No focus trap | Implement focus trapping or use a tested library |
| Spinner never disappears | `hx-indicator` target wrong or request errored silently | Check selector and add `hx-on:htmx:response-error` handler |
| Alpine state reset unexpectedly | HTMX swapped out the `x-data` root element | Scope Alpine state above the HTMX swap target |
| `hx-boost` breaks a form | `hx-boost` doesn't handle non-GET forms as expected | Remove `hx-boost` from that element; use explicit `hx-post` |

---

## Styling Defaults

Default to **daisyUI v5 component classes + Tailwind v4 utilities** for all markup examples in this stack. Do not hand-author CSS for things daisyUI already provides.

Examples:

- Buttons: `<button class="btn btn-primary">`
- Inputs: `<input class="input input-bordered">`
- Loading: `<span class="loading loading-spinner"></span>` instead of custom spinners
- Modals: daisyUI `<dialog class="modal">` rather than hand-rolled
- Alerts/toasts: `class="alert alert-success"`
- Menus, tabs, drawers, navbars: use daisyUI components

For `hx-indicator`, prefer daisyUI loading components:

```html
<button class="btn btn-primary" hx-post="/save">
  Save
  <span class="loading loading-spinner loading-sm htmx-indicator"></span>
</button>
```

Project setup (installing Tailwind+daisyUI, FastAPI build pipeline) is owned by the `setup-daisyui-tailwind-fastapi` skill.

## Companion Skills

- For visual direction, typography, color theme choice, layout rhythm, motion → load `frontend-design`
- For initial Tailwind + daisyUI + FastAPI setup → load `setup-daisyui-tailwind-fastapi`

## Authoritative Resources

- [HTMX Documentation](https://htmx.org/docs/)
- [Alpine.js Documentation](https://alpinejs.dev/)
- [Hypermedia Systems Book](https://hypermedia.systems/)
- [HTMX Essays](https://htmx.org/essays/)
