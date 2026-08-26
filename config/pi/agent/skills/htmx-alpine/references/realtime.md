# Real-Time Updates

Use HTMX's SSE and WebSocket extensions to receive server-pushed HTML. The server still renders HTML fragments — the client still just swaps them in.

## Table of Contents

1. [Choosing between SSE, WebSocket, and polling](#choosing-between-sse-websocket-and-polling)
2. [Server-Sent Events (SSE)](#server-sent-events-sse)
3. [WebSockets](#websockets)
4. [Out-of-band swaps in real-time streams](#out-of-band-swaps-in-real-time-streams)
5. [Reconnection and resilience](#reconnection-and-resilience)
6. [When to drop down to plain JS](#when-to-drop-down-to-plain-js)

---

## Choosing between SSE, WebSocket, and polling

| Pattern | Best for | Avoid for |
|---|---|---|
| Polling (`hx-trigger="every Xs"`) | Slow-changing data (status pages, dashboards refreshed every 30s+) | Anything user-perceived as "live" |
| SSE | Server pushes to client, one-way streams (notifications, feeds, progress) | Anything needing client → server messages on the same channel |
| WebSocket | Bidirectional streams (chat, collaborative editing, live cursors) | Cases where SSE would suffice — WS is more complex |

Default to SSE. Switch to WebSocket only when you need the client to send messages on the same channel.

## Server-Sent Events (SSE)

Include the SSE extension:

```html
<script src="https://unpkg.com/htmx-ext-sse@2.2.2"></script>
```

Connect with `hx-ext="sse"` and `sse-connect`:

```html
<div hx-ext="sse" sse-connect="/notifications/stream">
  <div sse-swap="message" hx-swap="afterbegin">
    <!-- Each `message` event swaps its data here -->
  </div>
</div>
```

The server sends events in the SSE format:

```
event: message
data: <li>New comment from Alice</li>

event: message
data: <li>New comment from Bob</li>
```

Each `data:` payload is HTML that gets swapped into the target.

For multiple event types, set up multiple swap targets:

```html
<div hx-ext="sse" sse-connect="/stream">
  <div sse-swap="comment" hx-swap="beforeend"></div>
  <div sse-swap="reaction" hx-swap="beforeend"></div>
</div>
```

Server then emits `event: comment` or `event: reaction`.

### Triggering a request from an SSE event

Instead of swapping the SSE data directly, you can use it to trigger another HTMX request:

```html
<div hx-ext="sse" sse-connect="/stream">
  <div hx-get="/items/latest"
       hx-trigger="sse:item-added"
       hx-swap="outerHTML">
  </div>
</div>
```

This is useful when the streamed event is small (just "something changed") but the swap target needs fuller HTML.

## WebSockets

Include the WS extension:

```html
<script src="https://unpkg.com/htmx-ext-ws@2.0.2"></script>
```

```html
<div hx-ext="ws" ws-connect="/chat/room/1">
  <div id="messages"></div>

  <form ws-send>
    <input name="text">
    <button>Send</button>
  </form>
</div>
```

- `ws-connect` opens the connection
- `ws-send` on a form sends its values as JSON when submitted
- The server pushes HTML fragments back; any element with an `id` is updated via OOB swap

The server-side message:

```html
<div id="messages" hx-swap-oob="beforeend">
  <p><strong>Alice:</strong> Hello!</p>
</div>
```

The server can push these any time — when this user sends a message, when another user sends a message, when a system notification arrives. The client just renders the HTML.

## Out-of-band swaps in real-time streams

OOB swaps are how a single SSE event or WS message updates multiple parts of the page. The streamed payload is an HTML fragment containing multiple elements marked `hx-swap-oob="true"`:

```html
<!-- One server message updates the feed, badge, and last-seen timestamp -->
<li id="feed" hx-swap-oob="afterbegin">New post from Alice</li>
<span id="unread-count" hx-swap-oob="true">7</span>
<time id="last-seen" hx-swap-oob="true">just now</time>
```

This is the right pattern for "something changed; reflect it everywhere it appears."

## Reconnection and resilience

SSE clients reconnect automatically when the connection drops. The HTMX SSE extension exposes events you can hook:

```html
<div hx-ext="sse"
     sse-connect="/stream"
     hx-on:htmx:sse-open="document.getElementById('status').textContent = 'Connected'"
     hx-on:htmx:sse-error="document.getElementById('status').textContent = 'Reconnecting…'">
  ...
</div>
```

For WebSocket, listen for `htmx:ws-open`, `htmx:ws-close`, `htmx:ws-error`.

For SSE with state replay (so a reconnecting client doesn't miss events), implement the `Last-Event-Id` header server-side. The browser sends the last event ID it saw on reconnect; the server replays anything newer.

## When to drop down to plain JS

Stay with HTMX extensions for almost everything. Drop down to a hand-written WebSocket client only when:

- The protocol is binary (audio/video streaming)
- You need a non-HTTP WS subprotocol
- You're integrating with a third-party WS service that doesn't speak HTML

Even then, isolate the JS to a single component and let the rest of the page stay HTMX-native.
