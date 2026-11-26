#!/bin/bash
# Assertion helpers for USM sandbox test cases.

set -euo pipefail

ASSERT_FAILS=0

_assert_fail() {
  printf "  [FAIL] %s\n" "$1" >&2
  ASSERT_FAILS=$((ASSERT_FAILS + 1))
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="${3:-values equal}"
  if [[ "$expected" != "$actual" ]]; then
    _assert_fail "$label (expected='$expected', actual='$actual')"
  fi
}

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  local label="${3:-file contains pattern}"
  if ! grep -qE -- "$pattern" "$file" 2>/dev/null; then
    _assert_fail "$label (pattern='$pattern' not found in $file)"
  fi
}

assert_file_not_contains() {
  local file="$1"
  local pattern="$2"
  local label="${3:-file does not contain pattern}"
  if grep -qE -- "$pattern" "$file" 2>/dev/null; then
    _assert_fail "$label (unexpected pattern='$pattern' in $file)"
  fi
}

assert_file_exists() {
  local file="$1"
  local label="${2:-file exists}"
  if [[ ! -e "$file" ]]; then
    _assert_fail "$label (missing: $file)"
  fi
}

assert_file_not_exists() {
  local file="$1"
  local label="${2:-file does not exist}"
  if [[ -e "$file" ]]; then
    _assert_fail "$label (unexpectedly exists: $file)"
  fi
}

assert_order() {
  local file="$1"
  local first="$2"
  local second="$3"
  local label="${4:-expected call order}"
  local line1 line2
  line1=$(grep -nE -- "$first" "$file" 2>/dev/null | head -n 1 | cut -d: -f1)
  line2=$(grep -nE -- "$second" "$file" 2>/dev/null | head -n 1 | cut -d: -f1)
  if [[ -z "$line1" || -z "$line2" ]]; then
    _assert_fail "$label (missing match: first='$first', second='$second')"
  elif (( line1 >= line2 )); then
    _assert_fail "$label (line $line1 >= line $line2)"
  fi
}

assert_summary() {
  local suite="$1"
  if (( ASSERT_FAILS == 0 )); then
    printf "[PASS] %s\n" "$suite"
    return 0
  else
    printf "[FAIL] %s (%d failures)\n" "$suite" "$ASSERT_FAILS" >&2
    return 1
  fi
}
