# validation — design notes (v1)

This records the two decisions the task asked to pin down — **how a model is
declared** and **the error model** — plus the constraints that shaped them and
the follow-ups they imply. It tracks
[zaplang-io/zap#311](https://github.com/zaplang-io/zap/issues/311).

## Goal and non-goal

`validation` is a pydantic-style runtime validator for Zap: declare a model,
validate parsed JSON against it, read typed fields, dump back out. The engine is
written **natively in Zap**. Pydantic's performance core (`pydantic-core`) is
Rust and is explicitly *not* vendored; this library is the Zap-native analog of
that core, with an ergonomic declarative surface on top.

## Decision 1 — model declaration: a schema-driven core

### What was considered

Pydantic's headline ergonomic is *annotation-driven*: you write a class with
typed attributes and a metaclass turns the annotations into a validator. The
task suggested a `@model` decorator or a base type as possible Zap shapes. Three
options were on the table:

1. **`@model` decorator that generates a validator from a struct's fields.**
   Rejected: Zap's decorator support (#16) implements only `@derive(Eq, Repr)`
   and user reflection annotations; decorator *code generation* beyond that is
   explicitly "not implemented yet" at lowering. There is also **no field-level
   reflection** — `reflect_names` exposes struct-level annotation names, not the
   fields or their types — so nothing could read a struct's fields to build a
   validator, at decoration time or at runtime.
2. **A generic base type `Model[T]`.** Rejected for the same reason: without
   reflection on `T`'s fields there is nothing for the base to iterate.
3. **A declarative schema built from field specs.** Chosen.

### What was chosen

A model is a **`Schema`** — a named, ordered list of **`Field`**s — constructed
with ordinary builder functions:

```zap
auto User = validation.model("User", [
    validation.field("name",  validation.str_t(min_len=1, max_len=50)),
    validation.field("age",   validation.int_t(min=0, max=130)),
    validation.field("tags",  validation.list_t(validation.str_t(min_len=1))),
    validation.field("address", validation.model_t(address_schema)),
])
```

Per-type constraints live inside the `FieldType` enum variant
(`IntT(min,max)`, `StrT(min_len,max_len,pattern)`, `ListT(elem,min_len,max_len)`,
`ModelT(schema)`, …), so `field()` only carries the cross-cutting concerns
(`required`, `has_default`, `default`). `FieldType` is recursive — `ModelT`
nests a whole `Schema`, `ListT` nests an element `FieldType` — which is how
nested models and lists of models are expressed. `Schema`, `Field` and
`FieldType` form a reference cycle through the heap, which Zap allows (D-0023).

This is deliberately the **same split pydantic uses internally**: a
schema-driven validation *core*, with a declarative surface on top. Here the
surface is explicit builder calls rather than class annotations. Because the
builders are **free functions**, they get Zap's keyword/default arguments
(#298), so a schema reads much like a block of typed field declarations and
constraints are opt-in by name.

### Why this is the right v1, and the path to `@model`

The schema *is* the single source of truth for a model in v1; you read validated
data through typed accessors on `Model` (`get_int`, `get_str`, `get_model`, …)
rather than through a bespoke struct. That avoids duplicating the field list in
both a struct and a schema.

When Zap gains **field-level reflection** or a **code-generating decorator**, an
annotation-driven surface layers cleanly on top of this engine without changing
it: a future `@model` on a struct would, at compile time, read the struct's
typed fields and *emit exactly these `model(...)`/`field(...)` calls* (mapping
`int64 → int_t()`, `Optional[T] → required=False`, a field annotation like
`@constraint(min=0)` → the bound argument). The engine, the error model and the
`Model` accessors stay as-is; only the front door changes. v1 ships the durable
part — the native engine — and leaves the sugar for when the compiler can
support it.

## Decision 2 — error model

### Shape

Validation never raises on invalid data and never stops at the first problem. It
returns a `ValidationResult`:

```zap
enum ValidationResult:
    Ok(Model model)          # all fields valid; normalized data
    Err(list[ValErr] errors) # the COMPLETE list of failures
```

Every failure is a `ValErr`:

```zap
struct ValErr:
    str loc    # dotted/bracketed path: "", "address.zip", "tags[2].weight"
    str kind   # machine-readable category (see table)
    str msg    # human-readable description
```

### Collection and paths

The engine threads a single `list[ValErr]` through the whole traversal and
appends to it; it never short-circuits. One field can even contribute several
errors (e.g. a string that is both too long *and* fails its pattern). Paths are
built top-down: `_validate_object` joins the base path with each field name
(`base.name`), lists append `[i]` to the element path, and nesting composes
naturally — so a bad weight two levels down reports at `tags[1].weight`.

Field-level errors come out in **schema order** (deterministic). The only
input-ordered case — unknown keys under `extra="forbid"` — is sorted before
reporting, so the entire error list is deterministic and golden-testable.

### Error kinds

| `kind` | Raised when |
|---|---|
| `missing` | a required field with no default is absent |
| `type` | the JSON value is the wrong shape for the field type |
| `too_small` / `too_large` | a number is below `min` / above `max` |
| `too_short` / `too_long` | a string or list is shorter / longer than its bound |
| `pattern` | a string fails its `pattern=` regex |
| `extra_forbidden` | an unknown key under `extra="forbid"` |

### Type policy

Types are checked strictly against the JSON DOM, with one pragmatic coercion:
`float_t` accepts a JSON integer and widens it (so `1` validates as a number).
Booleans are **not** integers. Missing optional fields are simply omitted from
the normalized output unless they carry a default; absent required fields with a
default are filled from it. Extra input keys are dropped by default
(`extra="ignore"`, matching pydantic), or can be forbidden or passed through.

## Serialization

Input is the stdlib `JsonValue` DOM (`json.loads`), so the library inherits JSON
parsing for free. A validated `Model` holds the normalized data as a
`dict[str, JsonValue]`; `to_json()` wraps it as `JsonValue.Object` and `dumps()`
serializes via `json.dumps`. Validated data round-trips: dump a model and
re-validate it and you get `Ok` again (covered by the test suite).

## Language constraints that shaped the code

- **`and` / `or` are not short-circuiting** in Zap today (both operands always
  evaluate). The ubiquitous `i < len(xs) and xs[i] == v` guard therefore indexes
  out of bounds. Filed upstream against `zaplang-io/zap`; every guarded
  index/lookup in this library is written as nested `if`s instead. This is the
  sharpest gap for a Python-readable language and is worth fixing in the
  compiler.
- **An `Optional[T]` parameter cannot default to `None`** (codegen rejects it —
  the known generic-sink limitation). So optional constraints use open
  sentinels (`min`/`max` default to the int64/float64 extremes, `max_len`
  defaults to `-1`, `pattern` to `""`) and a `has_default` boolean, instead of
  `Optional` defaults. A nice side effect: all constraint data is first-order
  scalars, no option-unwrapping on the hot path.
- **No `regex` stdlib module**, so string patterns use a small built-in matcher
  (`src/validation/pattern.zap`) supporting a documented PCRE subset with
  full-string matching.

## Deferred (natural follow-ups)

- Annotation-driven `@model` surface (needs field reflection or decorator
  codegen upstream).
- Custom/user validator functions per field (`@validator`-style hooks).
- More constraints: `multiple_of`, numeric exclusive bounds, string
  `strip`/case-normalization, enum/choice fields, union types.
- Richer patterns (groups, alternation) in the matcher.
- A JSON Schema export/import, and the web-framework request/response binding
  that will consume this package.
