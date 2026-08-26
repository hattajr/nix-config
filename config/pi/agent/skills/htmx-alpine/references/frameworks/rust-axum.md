# HTMX + Alpine with Rust (Axum + Askama)

Server-side patterns for handling HTMX requests in Axum, using Askama templates to render HTML fragments.

## Table of Contents

1. [Setup](#setup)
2. [Detecting HTMX requests](#detecting-htmx-requests)
3. [Rendering fragments vs full pages](#rendering-fragments-vs-full-pages)
4. [Form handling](#form-handling)
5. [Response headers](#response-headers)
6. [Error handling](#error-handling)
7. [SSE with Axum](#sse-with-axum)

---

## Setup

`Cargo.toml`:

```toml
[dependencies]
axum = "0.7"
askama = "0.12"
askama_axum = "0.4"
tokio = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
tower-http = { version = "0.5", features = ["fs"] }
```

Basic app skeleton:

```rust
use axum::{routing::{get, post}, Router};

#[tokio::main]
async fn main() {
    let app = Router::new()
        .route("/", get(index))
        .route("/items", post(create_item))
        .route("/items/:id", get(show_item).delete(delete_item))
        .nest_service("/static", tower_http::services::ServeDir::new("static"));

    let listener = tokio::net::TcpListener::bind("0.0.0.0:3000").await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
```

## Detecting HTMX requests

HTMX sends `HX-Request: true` on all its requests. Use an extractor to distinguish:

```rust
use axum::http::HeaderMap;

fn is_htmx(headers: &HeaderMap) -> bool {
    headers.get("HX-Request").is_some()
}
```

Or a custom extractor for cleaner handlers:

```rust
use axum::{
    extract::FromRequestParts,
    http::{request::Parts, StatusCode},
};

pub struct HtmxRequest(pub bool);

#[axum::async_trait]
impl<S> FromRequestParts<S> for HtmxRequest
where
    S: Send + Sync,
{
    type Rejection = StatusCode;

    async fn from_request_parts(parts: &mut Parts, _: &S) -> Result<Self, Self::Rejection> {
        Ok(HtmxRequest(parts.headers.get("HX-Request").is_some()))
    }
}
```

Usage:

```rust
async fn show_item(HtmxRequest(is_htmx): HtmxRequest) -> impl IntoResponse {
    if is_htmx {
        ItemFragment { ... }.into_response()
    } else {
        ItemPage { ... }.into_response()
    }
}
```

## Rendering fragments vs full pages

Pattern: a "fragment" template renders only the content; a "page" template wraps the fragment in `<html>...</html>`. The same data drives both.

`templates/_item.html` (fragment):

```html
<article id="item-{{ id }}">
  <h2>{{ name }}</h2>
  <p>{{ description }}</p>
</article>
```

`templates/item.html` (full page):

```html
{% extends "base.html" %}
{% block content %}
  {% include "_item.html" %}
{% endblock %}
```

Rust:

```rust
#[derive(Template)]
#[template(path = "_item.html")]
struct ItemFragment { id: u64, name: String, description: String }

#[derive(Template)]
#[template(path = "item.html")]
struct ItemPage { id: u64, name: String, description: String }
```

The handler picks one based on `HX-Request`.

A helpful pattern: a single struct that knows how to render either:

```rust
struct Item { id: u64, name: String, description: String }

impl Item {
    fn render_response(self, is_htmx: bool) -> Response {
        if is_htmx {
            ItemFragment { id: self.id, name: self.name, description: self.description }
                .into_response()
        } else {
            ItemPage { id: self.id, name: self.name, description: self.description }
                .into_response()
        }
    }
}
```

## Form handling

HTMX submits forms as `application/x-www-form-urlencoded` by default. Use `axum::Form` to extract:

```rust
use axum::Form;
use serde::Deserialize;

#[derive(Deserialize)]
struct NewItem {
    name: String,
    description: String,
}

async fn create_item(
    HtmxRequest(is_htmx): HtmxRequest,
    Form(input): Form<NewItem>,
) -> Result<Response, AppError> {
    let item = db::insert_item(&input.name, &input.description).await?;

    // On success, return just the new row (HTMX appends it to the list)
    if is_htmx {
        Ok(ItemRow { id: item.id, name: item.name }.into_response())
    } else {
        Ok(Redirect::to(&format!("/items/{}", item.id)).into_response())
    }
}
```

For validation errors, re-render the form fragment with errors:

```rust
async fn create_item(
    Form(input): Form<NewItem>,
) -> Response {
    if input.name.is_empty() {
        return (
            StatusCode::UNPROCESSABLE_ENTITY,
            NewItemForm {
                name: input.name,
                description: input.description,
                name_error: Some("Name is required".into()),
            }
        ).into_response();
    }
    // ...
}
```

By default HTMX won't swap 4xx/5xx responses. Either:

1. Return 200 even for validation errors (the form HTML carries the error markup)
2. Configure HTMX to swap error responses: `htmx.config.responseHandling = [...]`
3. Send `HX-Reswap` header to force a swap

Pattern (1) is simplest and most common.

## Response headers

Use the `axum::http::HeaderMap` to set HX-* response headers:

```rust
use axum::http::{HeaderMap, HeaderValue};

async fn add_to_cart() -> impl IntoResponse {
    let mut headers = HeaderMap::new();
    headers.insert("HX-Trigger", HeaderValue::from_static("cart-updated"));

    (headers, CartButton { count: 3 }.into_response())
}
```

For triggering events with data:

```rust
headers.insert(
    "HX-Trigger",
    HeaderValue::from_str(r#"{"cart-updated": {"count": 3, "total": "42.00"}}"#).unwrap(),
);
```

Common HX-* response headers:

- `HX-Trigger` — dispatch a JS event after swap
- `HX-Redirect` — full client-side redirect
- `HX-Refresh: true` — force full page reload
- `HX-Push-Url` — push URL after swap
- `HX-Retarget` — change target before swap
- `HX-Reswap` — change swap method before swap

A helper crate worth considering: `axum-htmx` provides extractors and response builders for all these.

## Error handling

Define an app error type that renders as HTML:

```rust
use askama::Template;

#[derive(Debug)]
pub enum AppError {
    NotFound,
    BadRequest(String),
    Internal(anyhow::Error),
}

#[derive(Template)]
#[template(path = "_error.html")]
struct ErrorFragment {
    message: String,
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, message) = match self {
            AppError::NotFound => (StatusCode::NOT_FOUND, "Not found".into()),
            AppError::BadRequest(msg) => (StatusCode::BAD_REQUEST, msg),
            AppError::Internal(err) => {
                tracing::error!("internal error: {:?}", err);
                (StatusCode::INTERNAL_SERVER_ERROR, "Something went wrong".into())
            }
        };
        (status, ErrorFragment { message }).into_response()
    }
}
```

Now any `?` in handlers that returns `AppError` will render the error fragment with the right status.

## SSE with Axum

Axum has built-in SSE support:

```rust
use axum::response::sse::{Event, KeepAlive, Sse};
use futures::stream::{self, Stream};
use std::convert::Infallible;
use std::time::Duration;
use tokio_stream::StreamExt as _;

async fn notifications() -> Sse<impl Stream<Item = Result<Event, Infallible>>> {
    let stream = stream::repeat_with(|| {
        // Render a fragment per event
        let html = NotificationFragment {
            message: "Hello".into(),
        }.render().unwrap();

        Event::default().event("message").data(html)
    })
    .map(Ok)
    .throttle(Duration::from_secs(2));

    Sse::new(stream).keep_alive(KeepAlive::default())
}
```

Client:

```html
<div hx-ext="sse" sse-connect="/notifications">
  <div sse-swap="message" hx-swap="afterbegin"></div>
</div>
```

For real applications, drive the stream from a broadcast channel rather than `repeat_with`, so events come from real domain activity (database changes, queue messages, etc.).

## Useful crates

- `axum-htmx` — extractors and response builders for HX-* headers
- `askama_axum` — `IntoResponse` impl for Askama templates
- `tower-livereload` — auto-reload during development
- `axum-flash` — flash messages via signed cookies (useful for post-redirect-get with HTMX disabled)
