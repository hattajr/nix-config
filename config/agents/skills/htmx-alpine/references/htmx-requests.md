# HTMX Request Patterns

How to use HTMX attributes to talk to the server. The server always returns HTML fragments — never JSON.

## Table of Contents

1. [Core attributes](#core-attributes)
2. [Targets and swaps](#targets-and-swaps)
3. [Triggers](#triggers)
4. [Out-of-band swaps](#out-of-band-swaps)
5. [URL management](#url-management)
6. [Headers](#headers)
7. [Error handling](#error-handling)
8. [Common patterns](#common-patterns)

---

## Core attributes

| Attribute | Purpose |
|---|---|
| `hx-get="/url"` | GET request on trigger |
| `hx-post="/url"` | POST request on trigger |
| `hx-put`, `hx-patch`, `hx-delete` | Other HTTP verbs |
| `hx-target="#id"` | Where to put the response (defaults to the element itself) |
| `hx-swap="..."` | How to insert the response |
| `hx-trigger="..."` | What triggers the request (defaults to natural trigger) |
| `hx-vals='{"key":"value"}'` | Extra values to send |
| `hx-include="selector"` | Include other inputs in the request |
| `hx-confirm="message"` | Show confirm dialog before sending |
| `hx-disable` | Disable element while request in flight |
| `hx-indicator="selector"` | Element to show during request (gets `.htmx-request` class) |

## Targets and swaps

`hx-target` selects where the response HTML goes. `hx-swap` controls how.

| `hx-swap` value | Effect |
|---|---|
| `innerHTML` (default) | Replace target's children |
| `outerHTML` | Replace the target itself |
| `beforebegin` | Insert before target |
| `afterbegin` | Insert as target's first child |
| `beforeend` | Insert as target's last child |
| `afterend` | Insert after target |
| `delete` | Delete target (ignore response body) |
| `none` | Do nothing with the body (useful with OOB swaps) |

Swap modifiers (append with space):

- `swap:200ms` — delay before swap
- `settle:500ms` — settle phase duration (for transitions)
- `scroll:top` / `scroll:bottom` — scroll target after swap
- `show:#elem:top` — scroll a specific element into view
- `transition:true` — use View Transitions API

Example:

```html
<button
  hx-post="/cart/items"
  hx-target="#cart"
  hx-swap="outerHTML transition:true">
  Add to cart
</button>
```

## Triggers

Default triggers: `submit` for forms, `click` for everything else, `change` for inputs.

Override with `hx-trigger`:

```html
<!-- Search-as-you-type with 500ms debounce -->
<input
  type="search"
  name="q"
  hx-get="/search"
  hx-target="#results"
  hx-trigger="input changed delay:500ms, search">

<!-- Load when scrolled into view -->
<div hx-get="/more" hx-trigger="revealed" hx-swap="outerHTML">Loading...</div>

<!-- Poll every 5 seconds (use SSE instead when possible) -->
<div hx-get="/status" hx-trigger="every 5s">Status</div>

<!-- Fire on a custom event from anywhere on the page -->
<div hx-get="/notifications" hx-trigger="notification-arrived from:body"></div>
```

Trigger modifiers: `once`, `changed`, `delay:Xs`, `throttle:Xs`, `from:selector`, `target:selector`, `consume`, `queue:first|last|all|none`.

## Out-of-band swaps

A single response can update multiple parts of the page. The main response goes to `hx-target`; any element marked `hx-swap-oob="true"` (or `hx-swap-oob="outerHTML:#id"`) is swapped in by matching ID.

Server response:

```html
<!-- main target gets this -->
<div id="cart-summary">3 items · $42.00</div>

<!-- this updates a different element by ID -->
<span id="cart-badge" hx-swap-oob="true">3</span>
```

Use OOB for navbar counters, flash messages, and any side-effect of a request that shows in a different part of the page.

## URL management

After a swap, the URL bar can be updated so the back button works.

```html
<a hx-get="/products/42" hx-target="#main" hx-push-url="true">Widget</a>
```

- `hx-push-url="true"` — push the request URL
- `hx-push-url="/custom/path"` — push a specific path
- `hx-replace-url="true"` — replace instead of push (no history entry)

Always use one of these for navigation-style actions, or browser back/forward will skip them.

## Headers

HTMX sends these request headers automatically:

- `HX-Request: true` — distinguishes HTMX requests from full-page loads
- `HX-Target` — id of the target element
- `HX-Trigger` — id of the triggering element
- `HX-Current-URL` — current browser URL

The server can send these response headers to control behavior:

- `HX-Redirect: /path` — full client-side redirect (not a swap)
- `HX-Refresh: true` — force full-page refresh
- `HX-Push-Url: /path` — push URL after swap
- `HX-Trigger: event-name` — dispatch a JS event after swap (use this to coordinate with Alpine)
- `HX-Retarget: #other` — change target before swap
- `HX-Reswap: outerHTML` — change swap method before swap

## Error handling

HTMX swaps responses with status 200–399 by default. For 4xx and 5xx:

- Status code is left to the server, but HTMX will fire `htmx:responseError`
- Server can opt-in to swapping error responses by setting an `HX-Reswap` header, or you can globally configure: `htmx.config.responseHandling`

Listen for errors with `hx-on::response-error`:

```html
<form hx-post="/signup"
      hx-target="#result"
      hx-on::response-error="document.getElementById('error').textContent = 'Something went wrong'">
  ...
</form>
```

For network failures (server unreachable), listen for `htmx:sendError`.

## Common patterns

### Inline form validation

```html
<input
  name="email"
  hx-post="/validate/email"
  hx-trigger="blur changed"
  hx-target="next .error"
  hx-swap="innerHTML">
<span class="error"></span>
```

Server returns `<span class="error">Email is taken</span>` or an empty fragment.

### Infinite scroll

```html
<div hx-get="/items?page=2"
     hx-trigger="revealed"
     hx-swap="outerHTML">
  Loading...
</div>
```

Each page response ends with the next-page placeholder.

### Click-to-edit

```html
<div id="contact-name">
  <span>Alice</span>
  <button hx-get="/contacts/1/edit" hx-target="#contact-name" hx-swap="outerHTML">Edit</button>
</div>
```

Server returns the form. Form's save action swaps back to the read-only view.

### Active search

```html
<input type="search"
       name="q"
       hx-get="/search"
       hx-trigger="input changed delay:300ms, search"
       hx-target="#results"
       hx-indicator="#spinner">
<div id="spinner" class="htmx-indicator">Searching…</div>
<div id="results"></div>
```
