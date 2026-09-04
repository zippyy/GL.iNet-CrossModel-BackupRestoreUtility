#!/bin/sh
# Run all native-engine shell suites (vendored canonical runtime proofs).
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
for suite in native-archive native-strategy rollback-injection; do
  echo "== $suite =="
  sh "$root/test/$suite.sh"
done
echo "all native shell suites passed"
