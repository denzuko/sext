# test/policy

`opa test`-runnable specs for the example policies in `policy/examples/`,
proving the schema documented in `docs/schema.md` is actually usable for
Rego policy authoring -- not just asserting it in prose.

## Running

```sh
opa test policy/ test/policy/fixtures/
```

(Both directories are needed: `policy/` for the policy and its
`*_test.rego` file, `test/policy/fixtures/` for the fixture data the
tests load via OPA's directory-based data loading.)

## Fixtures

`fixtures/no_pre_wrapped_filter_args.{bad,good}.lisp` are real,
self-contained Lisp source -- `bad` reproduces the exact bug pattern
the policy in `policy/examples/no_pre_wrapped_filter_args.rego` exists
to catch (a value pattern-matched and conditionally wrapped *before*
being passed to a function whose own job is that same pattern-match);
`good` is the fixed version. `fixtures/*.json` are `sext`'s actual
output for each, generated via:

```sh
./roswell/sext test/policy/fixtures/no_pre_wrapped_filter_args.bad.lisp
./roswell/sext test/policy/fixtures/no_pre_wrapped_filter_args.good.lisp
```

and then each wrapped in a single-key JSON object (`{"bad_ast": [...]}`
/ `{"good_ast": [...]}`) before committing -- OPA's directory-based data
loading requires a JSON object at the top level, and needs distinct
keys per file in the same directory to avoid a data-merge conflict
(sext's own raw output is a top-level JSON *array*, the documented
shape in `docs/schema.md` -- the wrapper key here is purely an
artifact of how `opa test` loads fixture data, not part of sext's
actual output contract).

**Why `uiop:ensure-list` and not the original `invoke-filter-chain`
from the actual mlisp bug**: verified directly (see issue #14) that
`sext` currently can only successfully dump source where every called
function is a standard/built-in CL function or already loaded into
the running image -- not a function merely defined earlier in the same
file or dump call, since `dump-string`/`dump-file` convert source to
an AST data structure without ever executing it. `uiop:ensure-list` is
a real, always-loaded (ships with ASDF) function that does exactly the
same "ensure a value is list-shaped" job as the original
`invoke-filter-chain`, making it possible to build a genuinely
dumpable, self-contained fixture today. Revisit once issue #14 is
resolved -- the policy's `canonical_disambiguators` set already
includes the original `invoke-filter-chain` name for when that's
possible again.

## Regenerating fixtures

If `sext`'s output shape ever changes (a Cleavir upgrade via `qlfile`,
for instance -- see `docs/schema.md`'s "Stability" section), regenerate
both fixture `.json` files with the commands above, re-wrap them the
same way, and re-run `opa test` to confirm the policy still passes
against the new shape.
