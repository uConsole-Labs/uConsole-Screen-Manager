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

printf "\n=== 3. Static Undefined Constant Check (src/usm-cli.sh) ===\n"
UNDEF_VARS=0
while IFS= read -r hit; do
  printf "  [UNDEF] %s\n" "$hit" >&2
  UNDEF_VARS=$((UNDEF_VARS + 1))
done < <(
  awk '
    BEGIN {
      n = split("HOME PATH WAYLAND_DISPLAY XDG_RUNTIME_DIR BASH_REMATCH " \
                "BASH_SOURCE LINENO SECONDS UID EUID PIPESTATUS IFS PWD " \
                "TMPDIR USER TERM LANG LC_ALL DISPLAY " \
                "DBUS_SESSION_BUS_ADDRESS", arr, " ")
      for (i = 1; i <= n; i++) allow[arr[i]] = 1
    }
    /^[[:space:]]*#/ { next }
    {
      line = $0
      gsub(/\047[^\047]*\047/, "", line)
      sub(/[[:space:]]+#.*/, "", line)
      dline = line
      sub(/^[[:space:]]*(readonly[[:space:]]+|export[[:space:]]+)?/, "", dline)
      if (match(dline, /^[A-Z][A-Z0-9_]+(\+?=)/)) {
        v = substr(dline, 1, RLENGTH)
        sub(/\+?=$/, "", v)
        def[v] = 1
      }
      tmp = line
      while (match(tmp, /\$\{?[A-Z][A-Z0-9_]+/)) {
        v = substr(tmp, RSTART, RLENGTH)
        sub(/^\$\{?/, "", v)
        if (!(v in used_line)) used_line[v] = NR
        tmp = substr(tmp, RSTART + RLENGTH)
      }
      tmp = line
      while (match(tmp, /\(\([^)]*\)\)/)) {
        etmp = substr(tmp, RSTART, RLENGTH)
        tmp = substr(tmp, RSTART + RLENGTH)
        while (match(etmp, /[A-Z][A-Z0-9_]+/)) {
          v = substr(etmp, RSTART, RLENGTH)
          if (!(v in used_line)) used_line[v] = NR
          etmp = substr(etmp, RSTART + RLENGTH)
        }
      }
    }
    END {
      for (v in used_line) {
        if (v in def || v in allow || v ~ /^USM_/) continue
        printf "src/usm-cli.sh:%d: %s\n", used_line[v], v
      }
    }
  ' "$REPO_ROOT/src/usm-cli.sh" | sort -t: -k2,2n
)
if (( UNDEF_VARS == 0 )); then
  printf "[PASS] No undefined constants/globals in src/usm-cli.sh\n"
else
  printf "[FAIL] Found %d undefined constant(s) in src/usm-cli.sh\n" \
    "$UNDEF_VARS" >&2
  FAILED=$((FAILED + 1))
fi

printf "\n=== 4. Running Modular Sandbox Test Cases ===\n"
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
