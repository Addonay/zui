#!/usr/bin/env bash
# Compile-only foreign-target gate for the checked-in Win32 and Cocoa paths.
#
# A PASS means Zig compiled the requested target. It does not mean that the
# binary was launched or that native callbacks, IME, clipboard, DPI, or
# multi-window behavior worked on that operating system.
set -u

root_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
pass=0
unverified=0
failed=0

report() {
    local name="$1" status="$2" detail="$3"
    printf '%-28s %-11s %s\n' "$name" "$status" "$detail"
    case "$status" in
        PASS) pass=$((pass + 1)) ;;
        UNVERIFIED) unverified=$((unverified + 1)) ;;
        FAIL) failed=$((failed + 1)) ;;
    esac
}

printf 'ZUI foreign-target compile gate\n'
printf 'source root: %s\n\n' "$root_dir"

if ! command -v zig >/dev/null 2>&1; then
    report windows-gnu-compile UNVERIFIED "zig is unavailable; compile-only gate was not run"
    report macos-compile UNVERIFIED "zig is unavailable; compile-only gate was not run"
else
    if (cd "$root_dir" && zig build check -Dtarget=x86_64-windows-gnu --summary all); then
        report windows-gnu-compile PASS "compile-only target check succeeded; no Windows runtime claim"
    else
        report windows-gnu-compile FAIL "zig build check failed for x86_64-windows-gnu"
    fi

    if (cd "$root_dir" && zig build check -Dtarget=aarch64-macos-none --summary all); then
        report macos-compile PASS "compile-only target check succeeded; no macOS runtime claim"
    else
        report macos-compile FAIL "zig build check failed for aarch64-macos-none"
    fi
fi

printf '\nsummary: pass=%d unverified=%d fail=%d\n' "$pass" "$unverified" "$failed"
if [[ "${ZUI_COMPILE_REQUIRE-0}" == 1 && "$failed" -ne 0 ]]; then
    exit 1
fi
if [[ "${ZUI_COMPILE_REQUIRE-0}" == 1 && "$unverified" -ne 0 ]]; then
    exit 2
fi
exit 0
