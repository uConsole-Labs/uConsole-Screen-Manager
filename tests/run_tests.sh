#!/bin/bash
# Main entrypoint for USM static checks and modular sandbox test suite.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

printf "=== 1. Syntax & ShellCheck Verification ===\n"
mapfile -t SHELL_FILES < <(
  find "$REPO_ROOT/src" "$REPO_ROOT/tests" -type f \
    \( -name "*.sh" -o -path "*/tests/mocks/*" \) | sort
)
for f in "${SHELL_FILES[@]}"; do
  bash -n "$f"
done
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "${SHELL_FILES[@]}"
  printf "[PASS] bash -n & shellcheck (%d files)\n" "${#SHELL_FILES[@]}"
else
  printf "[WARN] shellcheck not installed; bash -n passed (%d files)\n" \
    "${#SHELL_FILES[@]}"
fi

printf "\n=== 2. Line Length Check (<= 80 chars) ===\n"
LONG_LINES=0
for f in "${SHELL_FILES[@]}"; do
  while IFS= read -r hit; do
    printf "  [LONG] %s:%s\n" "$f" "$hit" >&2
    LONG_LINES=$((LONG_LINES + 1))
  done < <(
    awk 'length($0) > 80 && $0 !~ /https?:\/\// {
      printf "%d (%d chars): %s\n", NR, length($0), $0
    }' "$f"
  )
done
if (( LONG_LINES == 0 )); then
  printf "[PASS] All checked files <= 80 chars/line\n"
else
  printf "[FAIL] Found %d line(s) > 80 chars\n" "$LONG_LINES" >&2
  FAILED=$((FAILED + 1))
fi

printf "\n=== 3. Running Modular Sandbox Test Cases ===\n"
for test_script in "$REPO_ROOT"/tests/cases/test_*.sh; do
  if ! bash "$test_script"; then
    FAILED=$((FAILED + 1))
  fi
done

printf "\n=== Summary ===\n"
if (( FAILED == 0 )); then
  printf "All test suites PASSED.\n"
  exit 0
else
  printf "%d test suite(s) FAILED.\n" "$FAILED" >&2
  exit 1
fi
