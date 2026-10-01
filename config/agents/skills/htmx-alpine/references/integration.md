# HTMX + Alpine Integration

How the two libraries coordinate. The short version: HTMX swaps HTML, Alpine reacts to that HTML. They communicate via DOM events.

## Table of Contents

1. [How they coexist](#how-they-coexist)
2. [HTMX events Alpine can listen to](#htmx-events-alpine-can-listen-to)
3. [Dispatching events from the server](#dispatching-events-from-the-server)
4. [Reusable confirm dialog](#reusable-confirm-dialog)
5. [Multi-step forms](#multi-step-forms)
6. [Alpine inside swapped content](#alpine-inside-swapped-content)
7. [Preserving Alpine state across swaps](#preserving-alpine-state-across-swaps)

---

## How they coexist

A typical interactive element uses both:

```html
<button x-data="{ loading: false }"
        :disabled="loading"
        @htmx:before-request="loading = true"
        @htmx:after-request="loading = false"
        hx-post="/items"
        hx-target="#list">
  <span x-text="loading ? 'Saving…' : 'Save'"></span>
</button>
```

- HTMX does the request and swaps the result
- Alpine handles the disabled state and label

Scope matters: declare `x-data` on an element that **won't** be swapped out, or its state will reset.

## HTMX events Alpine can listen to

HTMX dispatches DOM events you can hook in `@` listeners. The most useful:

| Event | When |
|---|---|
| `htmx:before-request` | Just before the request fires |
| `htmx:after-request` | After response received (success or error) |
| `htmx:before-swap` | After response, before DOM swap |
| `htmx:after-swap` | After DOM swap completes |
| `htmx:response-error` | Response with 4xx/5xx status |
| `htmx:send-error` | Network error |
| `htmx:timeout` | Request timed out |

Alpine listener syntax accepts these directly:

```html
<button @htmx:after-swap="open = false" hx-post="/items">Save</button>
```

For events on other elements, use `.window`:

```html
<div @htmx:after-swap.window="lastUpdate = new Date()"></div>
```

## Dispatching events from the server

The server can trigger DOM events on the client by setting the `HX-Trigger` response header. Alpine components anywhere on the page can listen.

Server (response header):

```
HX-Trigger: cart-updated
```

Or with data:

```
HX-Trigger: {"cart-updated": {"count": 3, "total": 42.00}}
```

Client:

```html
<div x-data="{ count: 0 }"
     @cart-updated.window="count = $event.detail.count">
  <span x-text="count"></span>
</div>
```

This is the cleanest way to keep multiple disconnected UI components in sync without OOB swaps for each one.

## Reusable confirm dialog

The `hx-confirm` attribute uses the browser's `confirm()` dialog, which is ugly and not customizable. Build a proper confirm dialog with Alpine that listens to HTMX's `htmx:confirm` event.

```html
<!-- Confirm dialog component, rendered once per page -->
<div x-data="confirmDialog()"
     @htmx:confirm.window="handleConfirm($event)"
     x-show="open"
     x-cloak
     role="dialog"
     aria-modal="true"
     class="dialog-overlay">
  <div class="dialog">
    <p x-text="message"></p>
    <button @click="confirm()" autofocus>Yes</button>
    <button @click="cancel()">No</button>
  </div>
</div>

<script>
function confirmDialog() {
  return {
    open: false,
    message: '',
    resolveEvent: null,

    handleConfirm(e) {
      // Intercept HTMX's confirm flow
      e.preventDefault();
      this.message = e.detail.question || 'Are you sure?';
      this.open = true;
      this.resolveEvent = e.detail;
    },

    confirm() {
      this.open = false;
      this.resolveEvent.issueRequest(true);  // skip future confirms
    },

    cancel() {
      this.open = false;
    },
  };
}
</script>

<!-- Anywhere on the page -->
<button hx-delete="/items/42" hx-confirm="Delete this item?">Delete</button>
```

The `hx-confirm` text becomes the `message` shown in the Alpine dialog.

## Multi-step forms

For a wizard, persist each step to the server. Use Alpine only for in-step state (the field currently focused, validation state, etc.).

```html
<!-- Step 1 returned by GET /signup/step/1 -->
<form hx-post="/signup/step/1" hx-target="#wizard" hx-swap="outerHTML">
  <fieldset x-data="{ email: '' }">
    <label>Email <input x-model="email" name="email"></label>
    <button :disabled="!email.includes('@')">Next</button>
  </fieldset>
</form>
```

The server validates, saves to the session, and returns Step 2's HTML — which contains its own `<form>` and its own `x-data` for that step. Don't try to keep "wizard state" in Alpine across steps; the server holds it.

## Alpine inside swapped content

When HTMX swaps in HTML containing `x-data` attributes, Alpine initializes them automatically (Alpine 3 + watches mutations). You usually don't need to do anything.

If you find Alpine isn't initializing in swapped content, ensure:

1. Alpine is loaded with the `defer` attribute, **after** HTMX
2. You're on Alpine 3.x (Alpine 2 needed manual reinitialization)

For very dynamic content, you can manually call `Alpine.initTree(element)` after a swap, but this should rarely be needed.

## Preserving Alpine state across swaps

If a swap replaces an element that has `x-data`, that state is lost. Two strategies:

**1. Scope state above the swap target:**

```html
<div x-data="{ tab: 'a' }">
  <nav>
    <button @click="tab = 'a'">A</button>
    <button @click="tab = 'b'">B</button>
  </nav>
  <!-- swap target is inside x-data, so `tab` survives swaps -->
  <div id="content" hx-get="/load" hx-trigger="load">…</div>
</div>
```

**2. Use `hx-preserve` for elements that should survive their parent's swap:**

```html
<div id="form-region">
  <input hx-preserve="true" id="draft" name="draft">
  <!-- the rest gets swapped, draft input keeps its value -->
</div>
```

**3. Use Alpine.store for global state**, which is never tied to any DOM element.
