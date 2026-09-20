#!/usr/bin/env bash
# Reproducible native Linux capability probe for ZUI's checked-in adapters.
#
# A PASS below means that the host exposed the protocol/service or that the
# checked-in source contract was found. An UNVERIFIED result means that a
# real external actor (input method, second clipboard/drag client, or screen
# reader) is required; this script never fabricates those events.
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

has_cmd() { command -v "$1" >/dev/null 2>&1; }
has_env() { [[ -n "${!1-}" ]]; }

printf 'ZUI native Linux validation\n'
printf 'source root: %s\n\n' "$root_dir"

if [[ "$(uname -s)" != Linux ]]; then
    report host "UNVERIFIED" "Linux-only probe on $(uname -s)"
    exit 0
fi

# Source-contract checks are deliberately separate from live protocol checks.
if grep -q 'preedit_string' "$root_dir/src/platform/linux/wayland.zig" &&
   grep -q 'commit_string' "$root_dir/src/platform/linux/wayland.zig" &&
   grep -q 'delete_surrounding_text' "$root_dir/src/platform/linux/wayland.zig" &&
   grep -q 'done' "$root_dir/src/platform/linux/wayland.zig" &&
   grep -q 'zwp_text_input_manager_v3' "$root_dir/src/platform/linux/wayland.zig" &&
   grep -q 'default_text_input_listener' "$root_dir/src/platform/linux/wayland.zig" &&
   grep -q 'const tm = .*text_input_manager_interface' "$root_dir/src/platform/linux/wayland.zig" &&
   grep -q 'wl_proxy_add_listener.*default_text_input_listener' "$root_dir/src/platform/linux/wayland.zig"; then
    report checked-in-text-input-contract PASS "Wayland text-input-v3 callbacks, listener, and bind path present"
else
    report checked-in-text-input-contract FAIL "expected text-input-v3 callbacks, listener, or bind path missing"
fi
if grep -q 'XIMPreeditDrawCallbackStruct' "$root_dir/src/platform/linux/x11.zig" &&
   grep -q 'lookupHasText' "$root_dir/src/platform/linux/x11.zig" &&
   grep -q 'XOpenIM' "$root_dir/src/platform/linux/x11.zig" &&
   grep -q 'XCreateIC' "$root_dir/src/platform/linux/x11.zig" &&
   grep -q 'XFilterEvent' "$root_dir/src/platform/linux/x11.zig"; then
    report checked-in-xim-contract PASS "XIM callbacks, open/create, filter, and committed-text paths present"
else
    report checked-in-xim-contract FAIL "expected XIM callback/open/create/filter path missing"
fi
if grep -q 'DataDeviceListener' "$root_dir/src/platform/linux/wayland.zig" &&
   grep -q 'default_data_device_listener' "$root_dir/src/platform/linux/wayland.zig" &&
   grep -q 'XSelectionRequestEvent' "$root_dir/src/platform/linux/x11.zig" &&
   grep -q 'serveSelection' "$root_dir/src/platform/linux/x11.zig"; then
    report checked-in-transfer-contract PASS "Wayland data-device listener and X11 selection request/serve paths present"
else
    report checked-in-transfer-contract FAIL "clipboard/drag-drop listener or selection serve path missing"
fi

if grep -q 'test "x11 repeated open/close cycles' "$root_dir/src/platform/linux/x11.zig" &&
   grep -q 'destroyed' "$root_dir/src/platform/linux/wayland.zig"; then
    report checked-in-lifecycle-contract PASS "native close/reopen teardown paths and X11 cycle test present"
else
    report checked-in-lifecycle-contract FAIL "native lifecycle teardown coverage missing"
fi

if has_env WAYLAND_DISPLAY && has_cmd wayland-info; then
    wl_info="$(wayland-info 2>&1 || true)"
    if grep -q "zwp_text_input_manager_v3" <<<"$wl_info"; then
        report wayland-text-input-v3 PASS "compositor advertises zwp_text_input_manager_v3"
        report wayland-text-events UNVERIFIED "no external input-method driver supplied for preedit/commit/cancel/caret"
    else
        report wayland-text-input-v3 UNVERIFIED "Wayland is reachable but text-input-v3 is not advertised"
        report wayland-text-events UNVERIFIED "preedit/commit/cancel/caret cannot be exercised without text-input-v3"
    fi
    if grep -q "wl_data_device_manager" <<<"$wl_info"; then
        report wayland-data-device PASS "compositor advertises wl_data_device_manager"
        report wayland-clipboard-dnd UNVERIFIED "requires a second native data-device client and real offer/drop"
    else
        report wayland-data-device UNVERIFIED "Wayland is reachable but data-device manager is absent"
        report wayland-clipboard-dnd UNVERIFIED "clipboard/drag-drop cannot be exercised"
    fi
else
    report wayland-text-input-v3 UNVERIFIED "WAYLAND_DISPLAY or wayland-info unavailable"
    report wayland-text-events UNVERIFIED "no live Wayland compositor probe"
    report wayland-data-device UNVERIFIED "WAYLAND_DISPLAY or wayland-info unavailable"
    report wayland-clipboard-dnd UNVERIFIED "no live Wayland compositor probe"
fi

if has_env DISPLAY && has_cmd xprop; then
    xroot="$(xprop -root _NET_SUPPORTED 2>&1 || true)"
    if grep -q '_NET_SUPPORTED' <<<"$xroot"; then
        report x11-server PASS "X server accepted root-property query"
        if grep -q '_NET_WM_MOVERESIZE' <<<"$xroot"; then
            report x11-drag-protocol PASS "window-manager move/resize protocol advertised"
        else
            report x11-drag-protocol UNVERIFIED "window manager did not advertise move/resize"
        fi
        report x11-clipboard-dnd UNVERIFIED "requires a second X client and SelectionRequest/Xdnd transaction"
        if [[ -n "${XMODIFIERS-}" || -n "${GTK_IM_MODULE-}" || -n "${QT_IM_MODULE-}" ]]; then
            report x11-xim-configured UNVERIFIED "input-method variables set; requires live XIM client/server exchange"
        else
            report x11-xim-configured UNVERIFIED "no XIM environment configured; no preedit/commit/cancel/caret claim"
        fi
    else
        report x11-server UNVERIFIED "DISPLAY set but xprop could not query the X server"
        report x11-clipboard-dnd UNVERIFIED "X11 server unavailable"
        report x11-xim-configured UNVERIFIED "X11 server unavailable"
    fi
else
    report x11-server UNVERIFIED "DISPLAY or xprop unavailable"
    report x11-clipboard-dnd UNVERIFIED "no live X11 server probe"
    report x11-xim-configured UNVERIFIED "no live X11 server probe"
fi

if has_env DBUS_SESSION_BUS_ADDRESS && has_cmd gdbus; then
    atspi_enabled="$(gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus \
        --method org.freedesktop.DBus.Properties.Get org.a11y.Status IsEnabled 2>&1 || true)"
    screen_reader_enabled="$(gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus \
        --method org.freedesktop.DBus.Properties.Get org.a11y.Status ScreenReaderEnabled 2>&1 || true)"
    registry="$(gdbus introspect --session --dest org.a11y.atspi.Registry \
        --object-path /org/a11y/atspi/registry 2>&1 || true)"
    if grep -Eq "<'?true'?>|true" <<<"$atspi_enabled"; then
        report atspi-bus PASS "org.a11y.Bus reports IsEnabled=true"
        if grep -Eq "<'?true'?>|true" <<<"$screen_reader_enabled"; then
            report atspi-screen-reader-enabled PASS "org.a11y.Status reports ScreenReaderEnabled=true"
        else
            report atspi-screen-reader-enabled UNVERIFIED "AT-SPI bus is enabled, but no enabled screen-reader consumer was reported"
        fi
        if grep -q 'interface org.a11y.atspi.Registry' <<<"$registry"; then
            report atspi-registry PASS "org.a11y.atspi.Registry is reachable"
        else
            report atspi-registry UNVERIFIED "AT-SPI registry name/object was not introspectable"
        fi
        report atspi-semantic-publication UNVERIFIED "requires a live ZUI semantic tree observed by an external AT-SPI consumer"
    else
        report atspi-bus UNVERIFIED "AT-SPI bus unavailable or disabled"
        report atspi-screen-reader-enabled UNVERIFIED "AT-SPI bus unavailable or disabled"
        report atspi-registry UNVERIFIED "AT-SPI bus unavailable or disabled"
        report atspi-semantic-publication UNVERIFIED "no AT-SPI consumer available"
    fi
else
    report atspi-bus UNVERIFIED "session bus or gdbus unavailable"
    report atspi-screen-reader-enabled UNVERIFIED "session bus or gdbus unavailable"
    report atspi-registry UNVERIFIED "session bus or gdbus unavailable"
    report atspi-semantic-publication UNVERIFIED "no live AT-SPI probe"
fi

# A native close/reopen requires driving a running ZUI window from outside
# this process. The fixture is executable and the checked-in X11 cycle test
# is source-backed; keep the live claim explicitly open until a compositor
# runner is supplied.
report native-close-reopen UNVERIFIED "fixture and source test exist; no external ZUI window runner supplied"

printf '\nsummary: pass=%d unverified=%d fail=%d\n' "$pass" "$unverified" "$failed"
if [[ "${ZUI_NATIVE_REQUIRE-0}" == 1 && "$failed" -ne 0 ]]; then
    exit 1
fi
if [[ "${ZUI_NATIVE_REQUIRE-0}" == 1 && "$unverified" -ne 0 ]]; then
    exit 2
fi
exit 0
