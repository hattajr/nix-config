## Python Development Guidelines

### Environment
- Python 3.12+
- **All Python execution must go through `uv` — never use bare `python` or `python3`.**
- Run scripts: `uv run script.py`
- Run with env: `uv run --env-file .env script.py`
- Run tests: `uv run pytest`
- Scratch/test scripts: use uv inline script format with dependencies declared in the file header.
- Store all constants in `.env`.

### Dependencies
- Only well-known, actively maintained libraries.
- No unnecessary dependencies.
- **FastAPI** for web server, **Polars** for data, **PostgreSQL** with raw parameterized SQL (no ORM), Pydantic for data validation.

### Code Guidelines
- No emojis in code.
- No `print` — use the standard library **`logging`** module for all logging; never add loguru or other logging dependencies.
- Get loggers with `logger = logging.getLogger(__name__)`; configure handlers and format once at the entrypoint, never in library modules.
- Use lazy `%s` formatting (`logger.info("loaded %s rows", n)`), not f-strings.
- Follow YAGNI, DRY, SOLID.
- Prefer readability over cleverness; code should read like plain English.
- Small, focused, single-responsibility functions and classes.
- Use `@dataclass` for data-holding classes.

### Typing
- All functions must have type hints on parameters and return types.
- Prefer modern syntax: `list[str]`, `dict[str, int]`, `X | None`.
- Use `typing` module only when no modern equivalent exists (e.g. `TypeVar`, `Protocol`, `TypeAlias`).

### Async
- Prefer `async def` for all I/O-bound functions (DB queries, HTTP calls, file I/O).
- Never call blocking I/O inside async functions — use `asyncio.to_thread` for blocking operations.
- FastAPI route handlers must always be `async def`.

### Docstrings & Comments
- One-line description only, immediately after `def` or `class`.
- No parameter or return docs in docstrings.
- Comments explain **why**, never **what**.

### Error Handling
- Handle edge cases explicitly — no silent failures.
- Log clear, traceable error messages via `logging`; use `logger.exception(...)` inside `except` blocks to keep the traceback.

### Testing
- Use `pytest` via `uv run pytest`.
- Test files: `test_*.py`, test functions: `test_*`.
- Every non-trivial function needs at least one happy path and one edge case test.
- For quick experiments, write a uv inline script instead of a bare Python file.

### Type Checking & Linting
- `uvx ruff check --fix` and `uvx ruff format` for linting and formatting.
- `uvx pyright` for type checking.
- Code must pass both with zero errors.

### Definition of Done
- All functions have type hints and a docstring.
- use ruff to check for linting errors and formatting issues, and fix them.
- use pyright to check for type errors and fix them.
- No `print`, no emojis, no bare `python`/`python3` invocations.
- Tests exist for all non-trivial functions and pass via `uv run pytest`.

## Web Development
### Prefer stack
- HTMX & Alpine.js for SSR or frontend
- Vega for charting and plot
- Use Arrow format for sending big data to client/FE