#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
grep -q "^Summary: " docs/stages/s708.md
[ -f docs/decisions/0701-narrow-heavy-suites-whole-at-landing.md ]
python3 -c "
import tomllib
m = tomllib.load(open('.mason/mason.toml', 'rb'))['suite']
for n in ['test-StarCore', 'test-daemon', 'test-StarCpp', 'test-cli', 'test-pipeline', 'test-gui', 'test-desktop']:
    assert 'narrow_command' in m[n] and 'narrow_tests' in m[n] and 'whole_later' in m[n], n
for n in ['test-StarCore', 'test-gui', 'test-desktop']:
    assert m[n]['narrow_smoke'], n
for n in ['test-StarCore', 'test-daemon', 'test-pipeline', 'test-desktop']:
    assert m[n]['whole_later'] == 'ci', n
for n in ['test-gui', 'test-StarCpp', 'test-cli']:
    assert m[n]['whole_later'] == 'batch', n
assert 'STAR_USE_GPU_FOR_MERGE=0' in m['test-StarCore']['narrow_command']
for n in ['test-StarCpp-qos', 'test-gherkin', 'test-StarCpp-wgpu']:
    assert not any(k.startswith('narrow') or k == 'whole_later' for k in m[n]), n
l = tomllib.load(open('.mason/landing.toml', 'rb'))['tier'][0]['suites']
assert {'test-gui', 'test-StarCpp', 'test-cli', 'test-desktop'} <= set(l)
"
grep -q "pr-gate's macOS job covers the Swift side" .mason/mason.toml && exit 1
echo "s708 OK"
