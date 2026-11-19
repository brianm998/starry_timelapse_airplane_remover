# 0611: anchor the build suites' fail_regex

Task #598. Build suites print their pass marker only after `swift build` exits 0, so `fail_regex`
is a second gate. Its bare `error:` matched benign output (warning text quoting an error, names in
build logs) and turned a good build red, one source of test_red send-backs. It now matches
`(^|: )error: `, the shape of a real compiler diagnostic. Exit status still decides pass.
Not verified against a live run; test suites with 0 counted tests were not changed.
