# policy/examples/no_pre_wrapped_filter_args_test.rego
#
# `opa test policy/ test/policy/fixtures/` runs this. Fixtures are real
# `sext`-produced JSON (test/policy/fixtures/), not hand-written/synthetic
# input -- see test/policy/README.md for exactly how they were generated
# and how to regenerate them if sext's output shape ever changes.

package sext.examples.no_pre_wrapped_filter_args_test

import rego.v1
import data.sext.examples.no_pre_wrapped_filter_args.deny

test_denies_pre_wrapped_call if {
	count(deny) > 0 with input as data.bad_ast
}

test_allows_unwrapped_call if {
	count(deny) == 0 with input as data.good_ast
}
