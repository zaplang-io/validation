# quickstart — declare a model, validate good and bad input, dump back to JSON.
# Run with:  zap run quickstart.zap  (assembled next to the library by
# tools/build-examples.sh). It uses no network and is safe to run anywhere.

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
        # optional, with a default used when absent:
        validation.field("plan", validation.str_t(), required=False, has_default=True, default=JsonValue.Str("free")),
        validation.field("address", validation.model_t(address)),
        validation.field("roles", validation.list_t(validation.str_t(min_len=1), min_len=1)),
    ])

def main():
    auto schema = signup_schema()

    # A valid signup: construct and read typed fields, then dump back to JSON.
    auto ok = "{\"username\":\"ada\",\"age\":36,\"email\":\"ada@example.com\",\"address\":{\"city\":\"London\",\"zip\":\"90210\"},\"roles\":[\"admin\",\"user\"]}"
    match validation.validate_json(schema, ok):
        case validation.ValidationResult.Ok(m):
            print("valid signup for " + m.get_str("username") + " (plan=" + m.get_str("plan") + ")")
            print("  city=" + m.get_model("address").get_str("city"))
            print("  dumped=" + m.dumps())
        case validation.ValidationResult.Err(errs):
            print("unexpected: " + validation.errors_str(errs))

    # An invalid signup: too-short username, under-age, bad email, bad zip,
    # empty roles — all errors reported at once, with field paths.
    auto bad = "{\"username\":\"a\",\"age\":9,\"email\":\"nope\",\"address\":{\"city\":\"\",\"zip\":\"xx\"},\"roles\":[]}"
    match validation.validate_json(schema, bad):
        case validation.ValidationResult.Ok(m):
            print("unexpectedly valid")
        case validation.ValidationResult.Err(errs):
            print("rejected with " + str(len(errs)) + " errors:")
            print(validation.errors_str(errs))
