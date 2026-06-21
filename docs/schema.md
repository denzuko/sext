# sext JSON schema

This documents the actual shape of the JSON `sext:dump-string`/
`sext:dump-file`/`sext` (the CLI) produce, derived directly from
`src/walker.lisp` and Cleavir's own AST class definitions
(`Abstract-syntax-tree/general-purpose-asts.lisp` in the
[Cleavir](https://github.com/s-expressionists/Cleavir) monorepo), not
hand-designed independently of them. If anything here and the actual
output of a real `sext` run ever disagree, the real output is correct
and this file is stale -- please file an issue.

## Top-level shape

The output is a JSON array, with one entry per top-level form in the
source, in source order:

```json
[ <ast-node>, <ast-node>, ... ]
```

An empty or all-whitespace source produces `[]`.

## The AST node envelope

Every AST node -- the top-level entries above, and everywhere an AST
node appears nested inside another -- is a JSON object with this
shape:

```json
{
  "id": 1,
  "type": "call-ast",
  "origin": ...,
  "policy": false,
  ... type-specific fields ...
}
```

- **`id`** (integer): assigned sequentially, starting at 1, the first
  time each distinct AST node (by object identity, not by structural
  equality) is encountered during the walk of one `dump-string`/
  `dump-file` call. IDs are stable within a single dump, not across
  separate calls.
- **`type`** (string): the Cleavir AST class name, lowercased (e.g.
  `CALL-AST` -> `"call-ast"`). This is how you discriminate node kinds
  in Rego: `form.type == "call-ast"`.
- **`origin`**: the original source s-expression this node was derived
  from, as nested JSON arrays/strings/numbers (see "Value encoding"
  below) -- Concrete-Syntax-Tree's raw form, not a pretty-printed
  string. Frequently a compiler-generated temporary symbol (e.g.
  `"new609"`) rather than literal source text, for nodes Cleavir
  itself introduces during macroexpansion (`LET*`-bound temporaries
  from `DEFUN`'s expansion, for instance) -- this is expected, not a
  bug; see the worked example below.
- **`policy`**: Cleavir's compilation policy object for this node.
  Currently always `false` (JSON `false`, i.e. Lisp `NIL`) in sext's
  output, since `sext` doesn't bind a custom policy.
- Every field beyond these four is specific to the node's `type`, and
  corresponds exactly to that Cleavir AST class's own
  `CLEAVIR-IO:DEFINE-SAVE-INFO` declaration -- the field's JSON key is
  that declaration's initarg keyword, lowercased (e.g. Cleavir's
  `(:callee-ast callee-ast)` save-info entry on `call-ast` becomes the
  JSON key `"callee-ast"`).

## Value encoding

Values reachable from an AST node's fields (via Cleavir's `SAVE-INFO`)
are encoded as follows (`src/walker.lisp`'s `%WALK`):

| Lisp value | JSON encoding |
|---|---|
| An AST node (any `CLEAVIR-AST:AST` subclass instance) | The node envelope above, OR `{"ref": <id>}` if this exact object was already emitted earlier in the same dump (see "Object sharing" below) |
| `T` | `true` |
| `NIL` | `false` -- **not** `null`. A field holding `NIL` (no docstring, no name, attributes left at their nil default, etc.) reads as JSON `false`, not as a missing/null field. Always check `=== false`, not for key absence. |
| A Concrete-Syntax-Tree `CST` object | Walked as its underlying raw s-expression (`CONCRETE-SYNTAX-TREE:RAW`), recursively -- this is what makes `origin` fields nested JSON arrays rather than opaque object dumps |
| A cons (proper list) | A JSON array of each element, walked recursively |
| A symbol | A JSON string: the symbol's name, lowercased if the name is standard-case (read as all-uppercase, the normal case for unescaped symbols), left exactly as interned if genuinely mixed-case (created via `\|...\|` escapes) |
| A string | The JSON string, unchanged |
| A real number (integer, ratio, float -- not complex) | The JSON number, via `com.inuoe.jzon`'s normal number encoding |
| A vector (not a Lisp string) | A JSON array, each element walked recursively |
| Anything else | Falls back to a JSON string of `(princ-to-string value)` -- rare in practice; flagged here so a Rego policy author isn't surprised by an occasional plain string where they expected structure |

## Object sharing (`{"ref": id}`)

Cleavir's AST is mostly tree-shaped, but some nodes are deliberately
*shared*, most commonly a `lexical-variable` bound once and read or
`setq`'d multiple times -- the same Lisp object reachable from more
than one place in the tree. Re-expanding the same subtree at every
reachable point would be wasteful at best and unbounded if a true
cycle ever existed, so `sext` assigns each distinct node an `id` the
first time it's encountered (within one `dump-string`/`dump-file`
call) and emits a small back-reference object on every subsequent
encounter instead of re-expanding it:

```json
{ "ref": 6 }
```

A Rego policy walking the tree needs to either resolve `ref`s back to
the node they point at (build an `id -> node` index first, e.g. via
`walk()` over the whole array) or simply treat a bare `{"ref": N}`
object as "already seen, nothing new to check here" -- both are valid
strategies depending on what the policy needs.

## Common node types

This is not an exhaustive catalog -- Cleavir defines several dozen AST
classes, and the authoritative, always-current list is
`Abstract-syntax-tree/general-purpose-asts.lisp` in the Cleavir
source itself (search for `define-save-info`); duplicating that whole
list here would just go stale. These are the ones most Common Lisp
source actually produces and that came up directly in worked testing:

| `type` | Fields beyond `id`/`type`/`origin`/`policy` |
|---|---|
| `constant-ast` | `value` -- a literal constant |
| `lexical-variable` | `name` -- not itself a form; appears as the *binding* introduced by a `lexical-bind-ast`'s `lexical-variable` field or a `function-ast`'s `lambda-list` entries |
| `lexical-ast` | `lexical-variable` -- a *reference* to a previously bound variable; nearly always a `{"ref": id}` back to the `lexical-variable` node from its binding site |
| `lexical-bind-ast` | `lexical-variable`, `value-ast`, `ignore` -- one variable binding (what `LET`/lambda-list parameter binding compiles down to) |
| `constant-fdefinition-ast` | `name`, `attributes` -- a reference to a globally-named function, e.g. the `+` in `(+ a b)` |
| `call-ast` | `callee-ast`, `argument-asts`, `inline` -- a function call |
| `function-ast` | `lambda-list`, `body-ast`, `name`, `docstring`, `bound-declarations`, `original-lambda-list`, `attributes` -- a `lambda`/`defun` body. `lambda-list` here is a flat list of `lexical-variable` nodes (or small grouping lists for `&optional`/`&key` entries with their supplied-p variable), not the original surface lambda-list syntax -- use `original-lambda-list` for that |
| `progn-ast` | `form-asts` -- a sequence of forms; `DEFUN`'s expansion in particular produces *nested* `progn-ast`s, one per `LET*`-style binding introduced by sext's portable `DESTRUCTURING-BIND`/`DEFUN` expanders (see the worked example) |
| `block-ast` | `name`, `body-ast` -- a `cl:block` |
| `setq-ast` | `lexical-variable`, `value-ast` |
| `return-from-ast` | `block-ast`, `form-ast` -- `block-ast` here points directly at the target `block-ast` node (a `{"ref": id}` in practice), not at a name string |
| `if-ast` | `test-ast`, `then-ast`, `else-ast` -- `cl:cond`/`cl:when`/`cl:unless` all macroexpand down to this; there is no `cond-ast`/`when-ast` node type to match on |

## Worked example

`(defun add (a b) (+ a b))`, dumped via `sext` (the standalone
binary), pretty-printed:

```json
[
  {
    "id": 1, "type": "progn-ast",
    "origin": ["progn",
                ["setf", ["fdefinition", ["quote", "add"]],
                         ["lambda", ["a", "b"],
                                    ["block", "add", ["+", "a", "b"]]]],
                ["quote", "add"]],
    "policy": false,
    "form-asts": [
      {
        "id": 2, "type": "progn-ast", "origin": "new1485", "policy": false,
        "form-asts": [
          {
            "id": 3, "type": "lexical-bind-ast",
            "origin": "new1485", "policy": false,
            "lexical-variable": {
              "id": 4, "type": "lexical-variable",
              "origin": "new1485", "policy": false, "name": "new1485"
            },
            "value-ast": {
              "id": 5, "type": "function-ast",
              "origin": ["function", ["lambda", ["a", "b"],
                                                  ["block", "add", ["+", "a", "b"]]]],
              "policy": false,
              "lambda-list": [
                {"id": 6, "type": "lexical-variable", "origin": "a", "policy": false, "name": "a"},
                {"id": 7, "type": "lexical-variable", "origin": "b", "policy": false, "name": "b"}
              ],
              "body-ast": { "...": "id 8: another progn-ast, see below" },
              "name": false, "docstring": false, "bound-declarations": false,
              "original-lambda-list": ["a", "b"], "attributes": false
            },
            "ignore": false
          },
          { "...": "id 21: a call-ast invoking (setf fdefinition) -- see below" }
        ]
      }
    ]
  }
]
```

Three things worth calling out, all visible in the full (non-elided)
output:

1. **The outer shape is not what the source "looks like."** A
   one-line `defun` produces nested `progn-ast`/`lexical-bind-ast`
   wrapping, because `DEFUN` macroexpands (via sext's own portable
   expander, `src/environment.lisp`) to `(setf (fdefinition 'add)
   (lambda (a b) (block add (+ a b))))`, bound through a `LET*`-style
   temporary -- and *that's the actual semantics*, which is the entire
   point of dumping the AST rather than just `(read)`ing surface
   syntax (see the README's "Why not just `(read)` the source?").

2. **`id: 6` and `id: 7`** (the `lexical-variable` nodes for
   parameters `a`/`b`, introduced once in `function-ast`'s
   `lambda-list`) are referenced again later, deeper in the body, as
   `{"ref": 6}`/`{"ref": 7}` wherever `a`/`b` are subsequently *read*
   (inside the `+` call) -- exactly the object-sharing case described
   above, not a separate, structurally-identical-but-distinct node.

3. **The `(+ a b)` call** is, at the leaf, a `call-ast` whose
   `callee-ast` is a `constant-fdefinition-ast` with `"name": "+"`,
   and whose `argument-asts` are two `lexical-ast` nodes each wrapping
   a `{"ref": ...}` back to the parameter binding. This is the shape a
   Rego policy matching "calls to function X" needs: `form.type ==
   "call-ast"` and `form.callee-ast.type ==
   "constant-fdefinition-ast"` and `form.callee-ast.name == "+"`.

See `policy/examples/` for a complete, `opa eval`-tested Rego policy
written against this exact schema.

## Stability

This schema is a direct, mechanical reflection of Cleavir's own AST
class hierarchy -- it inherits Cleavir's stability characteristics,
not an independently-versioned contract `sext` maintains itself. If
Cleavir adds, renames, or changes the `SAVE-INFO` fields of an AST
class, `sext`'s output changes accordingly the next time `sext` is
built against that Cleavir revision, with no translation/compatibility
layer in between. `qlfile` pins Cleavir to a specific git commit for
exactly this reason -- a Rego policy author relying on field names
documented here should check `qlfile`'s pinned Cleavir commit when
diagnosing an unexpected schema change, not assume `sext` itself
changed.
