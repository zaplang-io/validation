# validation

A **pydantic-style runtime data-validation and typed-model library for Zap.**
Declare a model once, then validate parsed JSON against it: required vs optional
fields, type checks, value/length/pattern constraints, nested models and lists
of models — with **every** error collected and reported with a field path, not
just the first.

It is a non-core, official-tier Zap package (D-0056), installed by the Zap
package manager. The validation engine is implemented **natively in Zap** — it
does not wrap pydantic-core (which is Rust). Its only dependency is the stdlib
`json` DOM (`JsonValue`). This package is the keystone that the planned web
framework and JSON Schema packages build on (tracks
[zaplang-io/zap#311](https://github.com/zaplang-io/zap/issues/311)).

## Quick start

```zap
import validation

def signup_schema() -> validation.Schema:
    auto address = validation.model("Address", [
        validation.field("city", validation.str_t(min_len=1)),
        validation.field("zip", validation.str_t(pattern="[0-9]{5}")),
    ])
    return validation.model("Signup", [
        validation.field("username", validation.str_t(min_len=3, max_len=20)),
        validation.field("age", validation.int_t(min=13, max=120)),
        validation.field("email", validation.str_t(pattern="[^@ ]+@[^@ ]+\\.[a-z]{2,}")),
        # optional, with a default used when the key is absent:
        validation.field("plan", validation.str_t(), required=False, has_default=True, default=JsonValue.Str("free")),
        validation.field("address", validation.model_t(address)),
        validation.field("roles", validation.list_t(validation.str_t(min_len=1), min_len=1)),
    ])

def main():
    auto schema = signup_schema()
    match validation.validate_json(schema, input):
        case validation.ValidationResult.Ok(m):
            print(m.get_str("username") + " / " + m.get_str("plan"))
            print(m.get_model("address").get_str("city"))
            print(m.dumps())                      # serialize validated data
        case validation.ValidationResult.Err(errs):
            print(validation.errors_str(errs))    # one "loc: msg [kind]" per line
```

Running [`examples/quickstart.zap`](examples/quickstart.zap) prints:

```
valid signup for ada (plan=free)
  city=London
  dumped={"email":"ada@example.com","age":36,"username":"ada",...}
rejected with 6 errors:
username: string length 1 is less than minimum 3 [too_short]
age: value 9 is less than minimum 13 [too_small]
email: string does not match pattern [^@ ]+@[^@ ]+\.[a-z]{2,} [pattern]
address.city: string length 0 is less than minimum 1 [too_short]
address.zip: string does not match pattern [0-9]{5} [pattern]
roles: list length 0 is less than minimum 1 [too_short]
```

## How a model is declared

Zap v1 has no field-level reflection and no code-generating decorator, so there
is no metaclass-style `@model`-on-a-struct magic (yet — see
[DESIGN.md](DESIGN.md)). Instead a model is described **declaratively** as a
`Schema` you build from field specs. This is the same split pydantic itself
uses: a schema-driven *core* (this library) with a thin declarative surface on
top. The builders are ordinary functions with keyword/default arguments, so the
schema reads much like a list of typed field declarations.

### Field types (`FieldType`)

| Builder | Matches | Constraints |
|---|---|---|
| `int_t(min=, max=)` | JSON integer | inclusive numeric bounds |
| `float_t(min=, max=)` | JSON number (integers widened) | inclusive numeric bounds |
| `bool_t()` | JSON boolean | — |
| `str_t(min_len=, max_len=, pattern=)` | JSON string | codepoint length; regex-subset pattern |
| `model_t(schema)` | JSON object | validated against a nested `Schema` |
| `list_t(elem, min_len=, max_len=)` | JSON array | length; every element validated as `elem` |

All constraint arguments are optional (open sentinels mean "unbounded").

### Fields and models

```zap
validation.field(name, ftype, required=True, has_default=False, default=JsonValue.Null)
validation.model(name, fields, extra="ignore")   # extra: "ignore" | "forbid" | "allow"
```

### Validating and reading

```zap
validation.validate(schema, parsed_json_value) -> ValidationResult
validation.validate_json(schema, json_text)    -> ValidationResult   # parse + validate
```

`ValidationResult` is `Ok(Model)` or `Err(list[ValErr])`. A `Model` exposes
typed, validated accessors: `get_int`, `get_float`, `get_bool`, `get_str`,
`get_model` (nested), `get_list`, `get_models` (list of nested), `has`, plus
`to_json()` / `dumps()` to serialize the validated data back out.

A `ValErr` has `loc` (path like `address.zip` or `tags[2].weight`), `kind`
(`missing`, `type`, `too_small`, `too_large`, `too_short`, `too_long`,
`pattern`, `extra_forbidden`) and a human-readable `msg`. See
[DESIGN.md](DESIGN.md#error-model) for the full error model.

## String patterns

`str_t(pattern=...)` uses a small built-in regex matcher (Zap has no `regex`
stdlib module yet) that **full-matches** the string. Supported: `.`, literals,
character classes `[...]`/`[^...]` with ranges, `\d \w \s` and backslash
escapes, and quantifiers `* + ? {m} {m,} {m,n}`. Leading `^` / trailing `$` are
accepted and ignored (matching is always full-string). Groups, alternation,
back-references and lookaround are **not** supported in v1. See
[`src/validation/pattern.zap`](src/validation/pattern.zap).

## Build & test

No LLVM is needed on the host: everything runs through the prebuilt Zap
toolchain image published to GHCR
([zaplang-io/zap#277](https://github.com/zaplang-io/zap/pull/277)).

```bash
# Offline native test suite (compiles + runs the multi-module library):
docker run --rm -v "$PWD":/w -w /w ghcr.io/zaplang-io/zap:latest sh tools/run-tests.sh

# Compile-smoke the examples:
docker run --rm -v "$PWD":/w -w /w ghcr.io/zaplang-io/zap:latest sh tools/build-examples.sh
```

`tools/run-tests.sh` assembles a build root so Zap's entry-directory module
resolution (#283) finds the library (real multi-module compilation, no source
concatenation), runs `tests/validation_test.zap`, and diffs its stdout against
`tests/validation_test.expected`. The suite covers valid construction, each
constraint, missing-required, wrong-type, nested models, lists of models,
round-trip serialize/deserialize, multi-error collection, defaults, and the
extra-field policies. CI (`.github/workflows/ci.yml`) runs a hygiene check plus
this suite against the image on every push and PR.

## Layout

```
src/validation.zap          public API: builders, engine, and core types
src/validation/pattern.zap  self-contained regex-subset matcher
tests/validation_test.zap   golden test driver (+ .expected)
examples/quickstart.zap     runnable end-to-end example
tools/run-tests.sh          assemble build root, run + diff
tools/build-examples.sh     compile-smoke the examples
DESIGN.md                   model-declaration approach + error model
```

## Language friction

Two Zap gaps shaped this v1 (both noted here and, where new, filed upstream):

- **`and` / `or` do not short-circuit** — both operands are always evaluated, so
  the common `i < len(xs) and xs[i] == v` idiom indexes out of range. Filed as a
  new issue against `zaplang-io/zap`; the library works around it by writing
  every guarded index/lookup as nested `if`s. This is the one that would most
  surprise a Python reader.
- **An `Optional[T]` parameter cannot default to `None`** (codegen rejects it;
  the known generic-sink limitation). Optional constraints therefore use open
  numeric/length sentinels and `has_default` flags rather than `Optional`
  defaults — which keeps the builder signatures first-order and fast anyway.

There is no annotation-driven `@model` surface yet because Zap has no
field-level reflection or code-generating decorator; [DESIGN.md](DESIGN.md)
sketches how one would layer on top of this engine once those land.

## License

Apache-2.0. See [LICENSE](LICENSE).
