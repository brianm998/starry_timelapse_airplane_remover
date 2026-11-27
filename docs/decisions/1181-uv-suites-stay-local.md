# 1181 — uv suites stay local

Nodes (e.g. marmot) may lack `uv`, so `t0-pipeline-static` exited 127 and was judged a code red.
Decision: any suite whose command runs `uv` carries `remote = false`; a pytest enforces it.
Provisioning uv on nodes and classifying 127 as an environment fault are MASON-side work.
