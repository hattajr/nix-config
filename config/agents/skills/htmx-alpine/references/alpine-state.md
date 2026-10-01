# Alpine.js State Management

Alpine handles **ephemeral, UI-only state** that doesn't need to survive a page refresh. If state needs to persist or be authoritative, it belongs on the server.

## Table of Contents

1. [The golden rule](#the-golden-rule)
2. [Core directives](#core-directives)
3. [Scoping state](#scoping-state)
4. [Cross-component communication](#cross-component-communication)
5. [Persistence (when truly UI-only)](#persistence-when-truly-ui-only)
6. [Lifecycle hooks](#lifecycle-hooks)
7. [Common patterns](#common-patterns)
8. [Antipatterns](#antipatterns)

---

## The golden rule

> Alpine state is for state that, if lost on refresh, the application is still correct.

Good Alpine state: dropdown open/closed, tab selection, character count, form field focus, modal visibility, sidebar collapsed.

**Not** Alpine state: the user's saved items, their profile, items in a shopping cart, draft content they typed and want to recover, anything you'd ever query on the server.

If you find yourself thinking "I'll just keep this in Alpine so I don't have to round-trip," stop. Use HTMX.

## Core directives

| Directive | Purpose |
|---|---|
| `x-data="{ ... }"` | Declare a component and its state |
| `x-init="..."` | Run an expression when component initializes |
| `x-show="expr"` | Toggle `display: none` (element stays in DOM) |
| `x-if="expr"` | Conditionally render (element removed from DOM) — must wrap a `<template>` |
| `x-bind:attr="expr"` or `:attr="expr"` | Bind attribute to expression |
| `x-on:event="..."` or `@event="..."` | Event handler |
| `x-model="prop"` | Two-way bind input to state property |
| `x-text="expr"` | Set text content |
| `x-html="expr"` | Set innerHTML (use with care — sanitize first) |
| `x-for="item in items"` | Loop — must wrap a `<template>` |
| `x-ref="name"` | Get a reference to the element via `$refs.name` |
| `x-cloak` | Hidden until Alpine initializes (requires CSS) |
| `x-effect="..."` | Re-run expression when its dependencies change |
| `x-transition` | Apply transition classes on show/hide |
| `x-teleport="selector"` | Move element to another part of the DOM |

Required CSS for `x-cloak`:

```css
[x-cloak] { display: none !important; }
```

## Scoping state

State is scoped to the element declaring `x-data` and its children. Nested components inherit access to parent state and can add their own.

```html
<div x-data="{ open: false }">
  <button @click="open = !open">Toggle</button>
  <div x-show="open">
    <!-- has access to `open` -->
    <div x-data="{ count: 0 }">
      <!-- has access to both `open` and `count` -->
      <button @click="count++" x-text="count"></button>
    </div>
  </div>
</div>
```

For shared state across the page, use `Alpine.store`:

```html
<script>
  document.addEventListener('alpine:init', () => {
    Alpine.store('sidebar', { open: false });
  });
</script>

<button @click="$store.sidebar.open = !$store.sidebar.open">Menu</button>
<aside x-show="$store.sidebar.open">…</aside>
```

## Cross-component communication

Alpine components can dispatch and listen to custom events:

```html
<!-- dispatcher -->
<button @click="$dispatch('item-added', { id: 42 })">Add</button>

<!-- listener -->
<div @item-added.window="console.log($event.detail.id)"></div>
```

The `.window` modifier lets you listen anywhere on the page. This is also how you respond to HTMX events — see `integration.md`.

## Persistence (when truly UI-only)

For UI preferences only (theme, sidebar state), the `@alpinejs/persist` plugin can sync to localStorage:

```html
<div x-data="{ darkMode: $persist(false) }">
  <button @click="darkMode = !darkMode">Toggle theme</button>
</div>
```

Do **not** use this for anything that should be available across devices, that other users see, or that the server cares about. Those belong on the server.

## Lifecycle hooks

```html
<div x-data="{ count: 0 }"
     x-init="console.log('mounted')"
     @click.outside="count = 0">
  ...
</div>
```

- `x-init` runs after the component initializes
- `@click.outside` fires when clicking outside the element
- For more complex lifecycle, use Alpine's `init()` method inside `x-data`:

```html
<div x-data="{
  count: 0,
  init() {
    this.interval = setInterval(() => this.count++, 1000);
  },
  destroy() {
    clearInterval(this.interval);
  }
}">
  <span x-text="count"></span>
</div>
```

## Common patterns

### Dropdown

```html
<div x-data="{ open: false }" @click.outside="open = false">
  <button @click="open = !open">Menu</button>
  <ul x-show="open" x-transition>
    <li><a href="/profile">Profile</a></li>
    <li><a href="/logout">Log out</a></li>
  </ul>
</div>
```

### Tabs

```html
<div x-data="{ active: 'one' }">
  <nav>
    <button :class="{ active: active === 'one' }" @click="active = 'one'">One</button>
    <button :class="{ active: active === 'two' }" @click="active = 'two'">Two</button>
  </nav>
  <div x-show="active === 'one'">Panel one</div>
  <div x-show="active === 'two'">Panel two</div>
</div>
```

### Character counter

```html
<div x-data="{ text: '' }">
  <textarea x-model="text" maxlength="280"></textarea>
  <span x-text="`${text.length} / 280`"></span>
</div>
```

### Modal with focus management

```html
<div x-data="{ open: false }"
     @keydown.escape.window="open = false">
  <button @click="open = true">Open modal</button>

  <template x-teleport="body">
    <div x-show="open"
         x-trap.noscroll="open"
         role="dialog"
         aria-modal="true"
         class="modal-overlay">
      <div class="modal">
        <button @click="open = false">Close</button>
        ...
      </div>
    </div>
  </template>
</div>
```

`x-trap` (from `@alpinejs/focus` plugin) traps focus inside the modal. Without it, keyboard users can Tab outside. See `accessibility.md`.

## Antipatterns

### Caching server data in Alpine

```html
<!-- BAD: cart count duplicated client-side -->
<div x-data="{ cartCount: 3 }">
  <button @click="cartCount++; fetch('/cart/add', { method: 'POST' })">Add</button>
  <span x-text="cartCount"></span>
</div>
```

The Alpine count will drift from the server count the moment anything goes wrong. Use HTMX with an OOB swap on the badge instead.

### Storing forms in Alpine to "save" them

```html
<!-- BAD: form data only in Alpine -->
<form x-data="{ form: { name: '', email: '' } }">
  <input x-model="form.name">
  <input x-model="form.email">
  <button @click="alert(JSON.stringify(form))">Save</button>
</form>
```

The form should submit via `hx-post`. Alpine is fine for tracking *unsaved* state (e.g. "form is dirty" warnings), but the source of truth is the server response after submission.

### Manually syncing Alpine with the DOM

```html
<!-- BAD: working around HTMX swaps -->
<div x-data="{ items: [] }">
  <button hx-post="/items" @htmx:after-swap="items = JSON.parse(document.getElementById('data').textContent)">
    Add
  </button>
</div>
```

If you're parsing HTML or JSON out of the DOM into Alpine state, you're fighting the architecture. Let the server render the new state directly via HTMX.
