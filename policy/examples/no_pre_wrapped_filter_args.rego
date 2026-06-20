# policy/examples/no_pre_wrapped_filter_args.rego
#
# EXAMPLE / REFERENCE POLICY ONLY. Not production policy for any
# specific organization -- demonstrates that the sext JSON schema is
# usable for Rego policy authoring. Real organizational policy belongs
# in a separate, organization-owned repo that depends on sext as a tool,
# the same way podcast-mgr's actual policy depends on but does not
# contain clang/opa/cdxgen.
#
# This example encodes, in Rego, the exact bug class found during the
# mlisp session that motivated this project: a function that receives
# a configured filter-program value and wraps it in (list value) BEFORE
# passing it to the canonical filter-chain function, which silently
# defeats that function's own internal type-dispatch logic. The fix
# was: never pre-wrap; pass the raw configured value through and let
# the canonical function handle all three cases (nil/string/list) itself.
#
# Generalized as a policy: "no function should pattern-match on the
# shape of a value about to be passed into a function whose entire
# purpose is to do that same pattern-match." This is checkable
# structurally: look for a CALL node whose argument is itself a
# COND/IF node containing nested LISTP/NULL type predicates, where the
# call target is a known canonical disambiguation function.
#
# NOTE: exact Rego syntax below is illustrative pseudocode against the
# sext JSON schema as currently speculative (schema not yet finalized --
# see CLAUDE.md). This file's job is to prove out the schema design
# during next-session implementation, not to be correct Rego on day one.

package sext.examples.no_pre_wrapped_filter_args

import rego.v1

# Deny if a CALL node's argument list contains a nested type-dispatch
# (LISTP/NULL check) immediately wrapping a value, where the call target
# is a function name matching a configured "canonical disambiguator"
# allowlist (e.g. invoke-filter-chain). This is exactly the bug pattern
# this example exists to demonstrate is structurally detectable.

canonical_disambiguators := {"invoke-filter-chain"}

deny contains msg if {
	some form in input
	form.type == "call"
	form.operator in canonical_disambiguators
	some arg in form.arguments
	arg.type == "cond"
	some clause in arg.clauses
	clause.test.type == "call"
	clause.test.operator in {"listp", "null"}
	msg := sprintf(
		"function %s receives a pre-disambiguated argument at %s -- ~
		 disambiguation logic should live inside %s itself, not at ~
		 the call site (see mlisp PR #137 for the exact bug this catches)",
		[form.operator, form.location, form.operator],
	)
}
