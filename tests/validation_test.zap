# Offline test driver for the validation library. It builds a schema with every
# field kind and constraint, runs good and bad input through it, and prints what
# it observes for golden comparison against tests/validation_test.expected
# (tools/run-tests.sh diffs the two). Printing + golden comparison is how the Zap
# compiler's own suite and the sibling non-core packages exercise values; it is
# deterministic and toolchain-version independent.
#
# Coverage: valid construction, each constraint (numeric min/max, string
# length, string pattern, list length), missing-required, wrong-type, nested
# models, list-of-models, round-trip serialize/deserialize, multi-error
# collection, defaults, and the extra-field policies.

import validation
import validation.pattern

# Build the schema under test: a User with a nested Address and a list of nested
# tags, plus assorted constraints.
def user_schema() -> validation.Schema:
    auto address = validation.model("Address", [
        validation.field("street", validation.str_t(min_len=1)),
        validation.field("zip", validation.str_t(pattern="[0-9]{5}")),
    ])
    auto tag = validation.model("Tag", [
        validation.field("key", validation.str_t(min_len=1)),
        validation.field("weight", validation.int_t(min=0, max=100)),
    ])
    return validation.model("User", [
        validation.field("name", validation.str_t(min_len=1, max_len=20)),
        validation.field("age", validation.int_t(min=0, max=130)),
        validation.field("score", validation.float_t(min=0.0, max=1.0)),
        validation.field("active", validation.bool_t()),
        validation.field("email", validation.str_t(pattern="[^@ ]+@[^@ ]+\\.[a-z]{2,}")),
        validation.field("nickname", validation.str_t(min_len=1), required=False),
        validation.field("role", validation.str_t(), required=False, has_default=True, default=JsonValue.Str("member")),
        validation.field("address", validation.model_t(address)),
        validation.field("tags", validation.list_t(validation.model_t(tag), min_len=1)),
    ])

def show(str label, validation.ValidationResult r):
    match r:
        case validation.ValidationResult.Ok(m):
            print(label + ": OK")
        case validation.ValidationResult.Err(errs):
            print(label + ": " + str(len(errs)) + " error(s)")
            for e in errs:
                auto where = e.loc
                if where == "":
                    where = "(root)"
                print("  - " + where + " [" + e.kind + "] " + e.msg)

def main():
    auto schema = user_schema()

    # 1) Fully valid input, including a nested model and a list of models.
    auto good = "{\"name\":\"Ada\",\"age\":36,\"score\":0.9,\"active\":true,\"email\":\"ada@example.com\",\"address\":{\"street\":\"1 Analytical Way\",\"zip\":\"90210\"},\"tags\":[{\"key\":\"vip\",\"weight\":10},{\"key\":\"beta\",\"weight\":5}]}"
    auto r1 = validation.validate_json(schema, good)
    show("valid", r1)
    match r1:
        case validation.ValidationResult.Ok(m):
            print("  name=" + m.get_str("name") + " age=" + str(m.get_int("age")) + " active=" + str(m.get_bool("active")))
            print("  role(default)=" + m.get_str("role") + " has_nickname=" + str(m.has("nickname")))
            auto addr = m.get_model("address")
            print("  address.zip=" + addr.get_str("zip"))
            print("  tag count=" + str(len(m.get_models("tags"))))
            auto first = m.get_models("tags")[0]
            print("  tags[0].key=" + first.get_str("key") + " weight=" + str(first.get_int("weight")))
            # 7) round-trip: dump the validated model back to JSON, re-validate.
            auto dumped = m.dumps()
            auto r1b = validation.validate_json(schema, dumped)
            print("  round-trip ok=" + str(r1b.is_ok()))
        case validation.ValidationResult.Err(e):
            print("  (unexpected errors)")

    # 2) Missing required fields (age, email, address, tags) + an optional one
    #    present but empty (nickname min_len=1). Default role still fills in.
    auto missing = "{\"name\":\"Bo\",\"score\":0.5,\"active\":false,\"nickname\":\"\"}"
    show("missing-required", validation.validate_json(schema, missing))

    # 3) Wrong types across the board.
    auto wrong = "{\"name\":123,\"age\":\"old\",\"score\":true,\"active\":\"yes\",\"email\":5,\"address\":[],\"tags\":{}}"
    show("wrong-type", validation.validate_json(schema, wrong))

    # 4) Constraint violations: name too long, age too large, score too large,
    #    email bad pattern, empty tags list (min_len=1), nested zip bad pattern,
    #    nested tag weight too large. All collected at once (multi-error).
    auto bad = "{\"name\":\"ThisNameIsWayTooLongToAccept\",\"age\":200,\"score\":2.5,\"active\":true,\"email\":\"not-an-email\",\"address\":{\"street\":\"x\",\"zip\":\"ABCDE\"},\"tags\":[{\"key\":\"\",\"weight\":500}]}"
    show("constraints", validation.validate_json(schema, bad))

    # 5) Nested-path errors through a list element (tags[1].weight).
    auto nested = "{\"name\":\"Cy\",\"age\":40,\"score\":0.1,\"active\":true,\"email\":\"cy@example.com\",\"address\":{\"street\":\"road\",\"zip\":\"00000\"},\"tags\":[{\"key\":\"ok\",\"weight\":1},{\"key\":\"bad\",\"weight\":999}]}"
    show("nested-path", validation.validate_json(schema, nested))

    # 6) Extra-field policy.
    auto strict = validation.model("Strict", [
        validation.field("a", validation.int_t()),
    ], extra="forbid")
    show("extra-forbid", validation.validate_json(strict, "{\"a\":1,\"b\":2,\"c\":3}"))
    auto lax = validation.model("Lax", [
        validation.field("a", validation.int_t()),
    ], extra="allow")
    match validation.validate_json(lax, "{\"a\":1,\"keep\":9}") :
        case validation.ValidationResult.Ok(m):
            print("extra-allow: OK kept=" + str(m.get_int("keep")))
        case validation.ValidationResult.Err(e):
            print("extra-allow: unexpected err")

    # 8) Top-level type error (input is not an object).
    show("not-object", validation.validate_json(schema, "[1,2,3]"))

    # 9) The pattern matcher subset, exercised directly.
    print("pat zip 90210=" + str(pattern.fullmatch("[0-9]{5}", "90210")))
    print("pat zip 9021=" + str(pattern.fullmatch("[0-9]{5}", "9021")))
