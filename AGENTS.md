# AGENTS.md - Coding Guidelines for TUI (Zig)

## Build/Test Commands

```bash
# Build all binaries (tui_runtime, backend_demo)
zig build

# Run the interactive demo
zig build demo

# Run all unit tests
zig build test

# Single test filter (run tests matching name)
zig build test -- <filter>
# Example: zig build test -- "render: focused input"
```

## Protocol Schema Validation

```bash
# Install dependency for schema checks
python3 -m pip install jsonschema

# Canonical schema drift check (schema <-> Zig types + docs examples)
python3 scripts/check_protocol_schema.py --docs docs/PROTOCOL.md

# Validate captured runtime/backend JSONL traffic against schema
python3 scripts/check_protocol_schema.py --jsonl tui_backend.jsonl --jsonl tui_events.jsonl
```

## Project Structure

- `src/bin/` - Executables (`tui_runtime.zig`, `backend_demo.zig`)
- `src/lib/` - Library code imported as `tui` module
- `src/test/` - Tests + test-only helpers (`testing_terminal.zig`)
- `scripts/` - Developer tooling and validation scripts (including protocol schema checks)

## Code Style

### Imports
- Standard import first: `const std = @import("std");`
- Then module imports: `const tui = @import("tui");`
- Extract specific modules: `const protocol = tui.protocol;`

### Formatting
- zig fmt .
- No external formatter; Zig compiler enforces style
- 4-space indentation (no tabs)
- Max line length: ~100 chars (soft limit)

### Naming
- `snake_case` - functions, variables, fields
- `CamelCase` - types, structs, unions, enums
- `SCREAMING_SNAKE_CASE` - constants (rare)
- `PascalCase` - error sets, but prefer Zig built-ins

### Types
- Use `union(enum)` for sum types (tagged unions)
- Prefer explicit error unions: `Error!Type`
- Use `?T` for optionals, not sentinel values
- Slice types over arrays for dynamic data

### Error Handling
- Return explicit error unions; don't use `anyerror`
- Use `try` for propagation, `catch` for handling
- Error messages via `std.debug.print()` to stderr
- Error format: `PREFIX_ERR reason=<snake_case>` or `PREFIX_OK kind=<name>`

### Memory Management
- Use `GeneralPurposeAllocator` in binaries
- Use `ArenaAllocator` for per-request allocations
- Always `defer` cleanup immediately after allocation
- Pattern: `var list: std.ArrayList(T) = .empty; defer list.deinit(allocator);`

### Patterns
- Use `anytype` for generic interfaces (terminal writers/readers)
- Struct literals with explicit field names: `.{ .field = value }`
- Switch exhaustive for unions; use `_ => {}` for ignoring variants
- JSONL protocol over pipes for runtime-backend communication

### Testing
- Tests live in `src/test/tests.zig`
- Mock terminals in `testing_terminal.zig`
- Use `testing.expect`, `testing.expectEqual`, `testing.expectEqualStrings`
- Prefer explicit error messages in test failures

## Protocol (Runtime <-> Backend)

- JSONL over stdin/stdout pipes
- Messages: `patch` (backend→runtime), `event` (runtime→backend), `clipboard`, `config`
- Canonical schema artifact: `protocol.schema.json`
- Run `scripts/check_protocol_schema.py` when protocol types/docs/schema change

## Compatibility Policy (Active Development)
- **No backwards compatibility guarantees.** This project is in active development; breaking changes are acceptable.
- **Prefer deletion over legacy support.** If you build a new approach that overlaps an older one, remove the legacy code paths/APIs/fields instead of keeping both.
- **Keep the repo “single-truth.”** Don’t add shims, adapters, feature flags, or dual implementations solely to preserve older behavior.
- **Demo must use the latest.** `zig build demo` should showcase the newest APIs/protocol shapes and should not rely on deprecated/legacy paths.
- **Breaking changes must be complete.** If you change behavior or protocol shapes, update in the same change:
  - Zig types + runtime/backend handling
  - `protocol.schema.json`
  - `docs/PROTOCOL.md` examples
  - tests (`zig build test`) and any JSONL fixtures used for validation
