# Accessibility for HTMX + Alpine Apps

Dynamic content breaks a lot of accessibility defaults. This file covers the patterns to keep apps usable for keyboard and screen-reader users.

## Table of Contents

1. [The four things that matter most](#the-four-things-that-matter-most)
2. [ARIA live regions](#aria-live-regions)
3. [Focus management after swaps](#focus-management-after-swaps)
4. [Modals and focus traps](#modals-and-focus-traps)
5. [Keyboard navigation](#keyboard-navigation)
6. [Form validation messages](#form-validation-messages)
7. [Loading and busy state](#loading-and-busy-state)
8. [`x-cloak` and flash of content](#x-cloak-and-flash-of-content)

---

## The four things that matter most

1. **Announce dynamic updates** with `aria-live` regions
2. **Move focus to new content** after navigation-like swaps
3. **Trap focus inside modals** and return it when they close
4. **Make everything keyboard-operable** (Tab, Enter, Escape)

If you do these four things, you'll catch the majority of accessibility bugs.

## ARIA live regions

When HTMX swaps content, screen readers don't know to announce it unless you tell them. Mark the swap target as a live region:

```html
<div id="search-results"
     aria-live="polite"
     aria-atomic="false"
     aria-busy="false">
</div>
```

- `aria-live="polite"` — announce when the user is idle (use for search results, status updates)
- `aria-live="assertive"` — interrupt immediately (use sparingly: errors, urgent alerts)
- `aria-atomic="true"` — announce the whole region on change; `false` — only announce what changed
- `aria-busy="true"` — set during loading to suppress partial announcements

You can update `aria-busy` automatically via HTMX events:

```html
<div id="results"
     aria-live="polite"
     aria-busy="false"
     hx-on:htmx:before-request="this.setAttribute('aria-busy', 'true')"
     hx-on:htmx:after-settle="this.setAttribute('aria-busy', 'false')">
</div>
```

For non-disruptive status updates (e.g. "3 items in cart"), prefer `role="status"`, which implies `aria-live="polite"`.

## Focus management after swaps

When a swap is navigation-like (opening a modal, switching tabs, loading a new view), move focus to the new content so keyboard users continue where they expect.

The `hx-on::after-settle` hook is a good place:

```html
<button hx-get="/profile/edit"
        hx-target="#main"
        hx-on::after-settle="document.getElementById('main').querySelector('h1, [tabindex]').focus()">
  Edit profile
</button>
```

For the focus target to be reachable programmatically, it needs `tabindex="-1"`:

```html
<!-- Returned by /profile/edit -->
<section>
  <h1 tabindex="-1">Edit profile</h1>
  ...
</section>
```

A page-wide convention helps: a known selector (e.g. `[data-focus-after-swap]`) that swapped content uses to mark its focus target.

```html
<body hx-on::after-settle="const t = document.querySelector('[data-focus-after-swap]'); if (t) t.focus();">
```

For smaller swaps (inline validation, badge update), don't move focus — it would be disorienting.

## Modals and focus traps

A modal must:

1. Move focus into itself when opening
2. Trap Tab/Shift+Tab so focus stays inside
3. Restore focus to the trigger when closing
4. Close on Escape

The cleanest way is to use Alpine's `@alpinejs/focus` plugin:

```html
<div x-data="{ open: false }">
  <button @click="open = true">Open</button>

  <template x-teleport="body">
    <div x-show="open"
         x-trap.noscroll="open"
         @keydown.escape.window="open = false"
         role="dialog"
         aria-modal="true"
         aria-labelledby="modal-title"
         class="modal-overlay">
      <div class="modal">
        <h2 id="modal-title">Confirm action</h2>
        <button @click="open = false">Cancel</button>
        <button @click="open = false">Confirm</button>
      </div>
    </div>
  </template>
</div>
```

`x-trap.noscroll` traps focus *and* prevents background scroll. When `open` returns to false, focus returns to the previously focused element automatically.

If you can't use the plugin, you need to:

- Save `document.activeElement` when opening
- Find first and last focusable elements; cycle Tab between them
- Restore focus to the saved element on close

This is enough work that the plugin is almost always the better choice.

## Keyboard navigation

Every interactive element must be reachable and operable from the keyboard:

- Use real `<button>` elements, not `<div>` with `@click`. Buttons get keyboard activation for free.
- For custom widgets (combobox, tablist), follow the [ARIA Authoring Practices Guide](https://www.w3.org/WAI/ARIA/apg/) patterns
- Test by tabbing through your page with the mouse unplugged

A common mistake:

```html
<!-- BAD: div with click handler, no keyboard support -->
<div @click="open = !open">Toggle</div>

<!-- GOOD: button is keyboard-operable by default -->
<button @click="open = !open">Toggle</button>
```

For Escape-to-close on modals/dropdowns:

```html
<div @keydown.escape.window="open = false">
```

For Enter/Space on custom interactive elements (only if you can't use a button), bind both:

```html
<div role="button"
     tabindex="0"
     @click="..."
     @keydown.enter.prevent="$el.click()"
     @keydown.space.prevent="$el.click()">
```

## Form validation messages

Associate error messages with their inputs using `aria-describedby` and `aria-invalid`:

```html
<label>
  Email
  <input name="email"
         type="email"
         aria-invalid="true"
         aria-describedby="email-error">
</label>
<span id="email-error" class="error">
  Please enter a complete email address.
</span>
```

For dynamic validation via HTMX, the error span can be `aria-live="polite"` so screen readers announce changes:

```html
<input name="email"
       hx-post="/validate/email"
       hx-trigger="blur changed"
       hx-target="next .error"
       aria-describedby="email-error">
<span id="email-error" class="error" aria-live="polite"></span>
```

Set `aria-invalid="true"` from the server when re-rendering an input with errors.

## Loading and busy state

For long operations, communicate state via both visual indicator and ARIA:

```html
<button hx-post="/process"
        hx-target="#result"
        aria-controls="result"
        hx-on:htmx:before-request="this.setAttribute('aria-busy', 'true')"
        hx-on:htmx:after-request="this.setAttribute('aria-busy', 'false')">
  Process
</button>
<div id="result" aria-live="polite"></div>
```

`aria-controls` tells assistive tech which region this button affects. `aria-busy` is announced.

## `x-cloak` and flash of content

Without `x-cloak`, Alpine components flash in their unprocessed state during page load (e.g. an `x-show="false"` element appears for a frame before being hidden). This is jarring for sighted users and can announce phantom content to screen readers.

Always include in your CSS:

```css
[x-cloak] { display: none !important; }
```

And use `x-cloak` on any Alpine element that controls its own visibility:

```html
<div x-data="{ open: false }" x-show="open" x-cloak>...</div>
```
