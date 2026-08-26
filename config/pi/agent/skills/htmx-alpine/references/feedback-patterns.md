# Feedback Patterns

Loading indicators, error messages, optimistic updates, and toasts — all the things that make an HTMX app feel responsive.

## Table of Contents

1. [Loading indicators](#loading-indicators)
2. [Disabling controls during requests](#disabling-controls-during-requests)
3. [Optimistic UI](#optimistic-ui)
4. [Error messages](#error-messages)
5. [Toasts and flash messages](#toasts-and-flash-messages)
6. [Empty states](#empty-states)

---

## Loading indicators

HTMX adds the `.htmx-request` CSS class to the element being requested (or the element pointed to by `hx-indicator`) for the duration of the request.

CSS approach:

```css
.htmx-indicator {
  opacity: 0;
  transition: opacity 200ms ease-in;
}
.htmx-request .htmx-indicator,
.htmx-request.htmx-indicator {
  opacity: 1;
}
```

```html
<button hx-post="/items" hx-indicator="#spinner">
  Save
  <img id="spinner" class="htmx-indicator" src="/spinner.svg" alt="">
</button>
```

For the indicator to live elsewhere on the page (e.g. a page-level progress bar), point `hx-indicator` at it by selector. Multiple elements can share one indicator.

### Inline spinner with Alpine

If you'd rather drive the spinner via Alpine:

```html
<button x-data="{ loading: false }"
        @htmx:before-request="loading = true"
        @htmx:after-request="loading = false"
        :disabled="loading"
        hx-post="/items">
  <span x-show="!loading">Save</span>
  <span x-show="loading" x-cloak>Saving…</span>
</button>
```

## Disabling controls during requests

The simplest approach: `hx-disable` automatically adds `disabled` to the element while the request is in flight.

```html
<button hx-post="/items" hx-disable>Save</button>
```

For broader disabling (e.g. an entire form), wrap with Alpine:

```html
<form x-data="{ submitting: false }"
      @htmx:before-request="submitting = true"
      @htmx:after-request="submitting = false"
      hx-post="/signup">
  <fieldset :disabled="submitting">
    <input name="email">
    <input name="password" type="password">
    <button>Sign up</button>
  </fieldset>
</form>
```

`<fieldset disabled>` disables all form controls inside it — the most reliable way to prevent double-submission and stray input.

## Optimistic UI

For ultra-fast interactions (like/unlike, toggle favorite), update the UI immediately and let HTMX confirm with the server. If the server disagrees, the swap corrects the UI.

```html
<button x-data="{ liked: false, count: 42 }"
        @click="liked = !liked; count += liked ? 1 : -1"
        hx-post="/posts/42/like"
        hx-swap="outerHTML">
  <span x-text="liked ? '♥' : '♡'"></span>
  <span x-text="count"></span>
</button>
```

The server's response (which includes the authoritative liked state and count) replaces the button. If the optimistic update was wrong, the user sees the corrected state.

Be cautious: optimistic UI is wrong for any action where the user must know the outcome before continuing (payment, deletion, anything irreversible).

## Error messages

### Per-request error region

```html
<form hx-post="/signup"
      hx-target="#result"
      hx-on::response-error="document.getElementById('error').textContent = 'Something went wrong. Please try again.'">
  ...
</form>
<div id="error" role="alert" aria-live="assertive"></div>
<div id="result"></div>
```

The `role="alert"` + `aria-live="assertive"` ensures screen readers announce errors immediately.

### Server-rendered error fragments

For validation errors, the server can return the form with errors embedded, swapping the whole form:

```html
<!-- Server response for invalid email -->
<form id="signup" hx-post="/signup" hx-swap="outerHTML">
  <label>
    Email
    <input name="email" value="alice@" aria-invalid="true" aria-describedby="email-err">
    <span id="email-err" class="error">Please enter a complete email address.</span>
  </label>
  <button>Sign up</button>
</form>
```

This pattern works without JS and is the most accessible — error messages are part of the document, associated with their inputs via `aria-describedby`.

### Global error handling

Catch errors at the document level for a consistent fallback:

```html
<body hx-on::response-error="showToast('Something went wrong')"
      hx-on::send-error="showToast('Network error — check your connection')">
  ...
</body>
```

## Toasts and flash messages

Use OOB swaps for transient notifications. Reserve a toast region on the page:

```html
<div id="toasts" aria-live="polite" aria-atomic="false"></div>
```

When the server wants to show a toast, include it in any response as an OOB swap:

```html
<!-- main response -->
<div id="cart-summary">…</div>

<!-- OOB toast -->
<div id="toasts" hx-swap-oob="afterbegin">
  <div x-data="{ show: true }"
       x-show="show"
       x-init="setTimeout(() => show = false, 4000)"
       x-transition
       role="status"
       class="toast toast-success">
    Item added to cart
  </div>
</div>
```

The toast auto-dismisses after 4 seconds. `aria-live="polite"` on the container announces it to screen readers.

## Empty states

When the server renders a list, include the empty-state markup in the same fragment so swaps naturally show it:

```html
<!-- Server response when list is empty -->
<ul id="items">
  <li class="empty-state">
    No items yet. <a href="/items/new" hx-get="/items/new" hx-target="#items">Add the first one</a>.
  </li>
</ul>
```

This avoids the bug where deleting the last item leaves a stale empty `<ul>` with no message.
