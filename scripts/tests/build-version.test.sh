#!/usr/bin/env bash
# Tests the version numbers and feed addresses scripts/build-app.sh gives release builds
# (--dry-run: nothing is built).
#   bash scripts/tests/build-version.test.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0; OUT=""
check() { if eval "$2"; then PASS=$((PASS + 1)); echo "  ✓ $1"; else FAIL=$((FAIL + 1)); echo "  ✗ $1"; echo "$OUT" | sed 's/^/      /'; fi; }
field() { sed -n "s/^$1=//p" <<<"$OUT"; }
dry() { OUT="$("$ROOT/scripts/build-app.sh" --dry-run "$@" 2>&1)"; }

echo "build numbers"
dry --release --tag v6.1.0-rc1; RC1="$(field build)"
check "rc1 is 6010001" '[[ "$RC1" == 6010001 ]]'
check "rc1's version is 6.1.0-rc1" '[[ "$(field version)" == 6.1.0-rc1 ]]'
dry --release --tag v6.1.0-rc2; RC2="$(field build)"
dry --release --tag v6.1.0; FINAL="$(field build)"
check "rc1 < rc2 < final" '(( RC1 < RC2 && RC2 < FINAL ))'
dry --release --tag v6.1.1-rc1; NEXT="$(field build)"
check "6.1.0 < 6.1.1-rc1" '(( FINAL < NEXT ))'
dry --release --tag v6.2; check "v6.2 reads as 6.2.0" '[[ "$(field build)" == 6020099 ]]'

echo "feeds"
dry --release --tag v6.1.0-rc1 --feed test; TEST="$(field feed)"
check "--feed test is appcast-test.xml" '[[ "$TEST" == https://github.com/*/releases/download/appcast/appcast-test.xml ]]'
dry --release --tag v6.1.0 --feed prod; PROD="$(field feed)"
check "--feed prod is appcast.xml" '[[ "$PROD" == https://github.com/*/releases/download/appcast/appcast.xml ]]'
dry --release --tag v6.1.0-rc1; check "an rc tag reads the test feed by default" '[[ "$(field feed)" == "$TEST" ]]'
dry --release --tag v6.1.0; check "a final tag reads the real feed by default" '[[ "$(field feed)" == "$PROD" ]]'
dry; check "a source build has no feed" '[[ -z "$(field feed)" ]]'

echo "refusals"
dry --release --tag 6.1.0; check "a tag without v is refused" '[[ "$OUT" == *"✗ tag must look like"* ]]'
dry --release --tag v6.1.0-beta1; check "a beta tag is refused" '[[ "$OUT" == *"✗ tag must look like"* ]]'
dry --release --tag v6.1.0-rc99; check "rc99 is refused" '[[ "$OUT" == *"rc must be 1 to 98"* ]]'
dry --release --tag v6.100.0; check "minor 100 is refused" '[[ "$OUT" == *"at most 99"* ]]'
dry --release --tag v6.1.0 --feed beta; check "an unknown feed is refused" '[[ "$OUT" == *"--feed must be test or prod"* ]]'
dry --release; check "--release without --tag is refused" '[[ "$OUT" == *"needs --tag"* ]]'
dry --tag v6.1.0; check "--tag without --release is refused" '[[ "$OUT" == *"only go with --release"* ]]'

echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
