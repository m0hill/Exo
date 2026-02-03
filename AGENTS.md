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

## Project Structure

- `src/bin/` - Executables (`tui_runtime.zig`, `backend_demo.zig`)
- `src/lib/` - Library code imported as `tui` module
- `src/test/` - Tests + test-only helpers (`testing_terminal.zig`)

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
- Messages: `patch` (backend→runtime), `event` (runtime→backend)
- Nodes: `vbox`, `text`, `input` with required `id` field
- Event types: `key`, `focus`, `input`
