# USM Architecture & Design Document

[點擊此處跳轉至中文版說明](#系統架構與設計文件-Traditional-Chinese)

This document explains the technical design and logic behind the uConsole
Screen Manager (USM). It outlines how USM interacts with the Linux kernel
and the Wayland compositor without relying on polling.

## 1. Design Objective

The uConsole Screen Manager (USM) is designed to dynamically manage external
displays on Raspberry Pi OS Trixie (Wayland / Labwc). It relies entirely on
real-time hardware event monitoring to seamlessly switch display outputs
without relying on continuous background polling.

## 2. System Architecture

USM monitors two event sources simultaneously and feeds all events into a
single handler loop inside `usm-cli.sh`.

```text
+------------------+   +---------------------------+
| Linux Kernel     |   | udevadm monitor           |
| (DRM Subsystem)  |-->| (HDMI plug/unplug)        |--+
+------------------+   +---------------------------+  |
                                                      | events
+------------------+   +---------------------------+  |
| logind (systemd) |-->| dbus-monitor              |--+
| (PrepareForSleep)|   | (suspend/resume signals)  |  |
+------------------+   +---------------------------+  |
                                                      v
                                             +-----------------+
                                             | usm-cli.sh      |
                                             | (cmd_monitor)   |
                                             +-----------------+
                                                      |
                                                      | 1. Validate HW (EDID)
                                                      | 2. Idempotency Check
                                                      | 3. Switch Display
                                                      v
                                             +--------------------+
                                             | Wayland Compositor |
                                             | (wlr-randr)        |
                                             +--------------------+
                                                      |
                                                      | 4. Execute Hooks
                                                      v
                                             +--------------------+
                                             | hook-plug.sh /     |
                                             | hook-unplug.sh     |
                                             +--------------------+
```

## 3. Core Design Principles

### A. Zero CPU Polling (Event-Driven)

USM monitors two event sources simultaneously inside a single `while read`
loop:

- `udevadm monitor --subsystem=drm`: blocks until the kernel emits a DRM
  hardware change event, used for HDMI plug/unplug detection.
- `dbus-monitor`: subscribes to the logind `PrepareForSleep` signal to
  handle system suspend and resume.

Both sources run as parallel background processes. When all hardware states
are static, USM consumes exactly 0% CPU.

### B. State Debounce and Hardware Re-verification

Monitors entering power-saving sleep modes (DPMS) frequently drop the Hot
Plug Detect (HPD) signal, causing the Linux kernel to emit a false
"disconnected" event. To prevent ghost switching, USM uses a two-stage
debounce strategy:

1. If an event arrives within DEBOUNCE_SEC seconds of the last processed
   event, it is immediately discarded without sleeping. This prevents event
   storms from queuing up multiple debounce waits.
2. Otherwise, USM sleeps for DEBOUNCE_SEC seconds to let the hardware
   state stabilise.
3. After the wait, USM actively re-reads the hardware DRM status.
4. If the state matches the previous state (i.e., a phantom disconnect),
   the event is safely ignored.

### C. Idempotence & State Matching (Fast-Bypass)

Before executing any display manipulation, USM actively probes the Wayland
compositor for the current output state (`Enabled: yes/no`). If the system
is already in the expected target state, USM safely bypasses the execution.
This guarantees silent boots and prevents screen flickering on redundant
triggers.

### D. The EDID Fail-Safe Mechanism

Checking if the HDMI port status is `connected` is insufficient due to false
positives during system wake-up. USM verifies the size of the EDID file
(`/sys/class/drm/card*-HDMI-A-1/edid`). If the size is greater than 0, USM
confirms a valid physical connection before proceeding.

### E. Display Mode Switching Strategies

The Raspberry Pi CM4's VC4 KMS driver often rejects atomic commits when
activating multiple high-resolution displays simultaneously due to momentary
CMA bandwidth exhaustion. USM handles this with two strategies:

1. **Direct Switch with Fallback (`ext` and `int` modes):**
   USM first attempts a direct switch in a single `wlr-randr` call. If it
   succeeds, the transition is complete. If the driver rejects the call, USM
   enters the fallback sequence: all outputs are disabled, a short wait is
   applied, and then only the target display is re-enabled. This avoids
   bandwidth conflicts from simultaneous dual-output activation.

2. **Low-res Sync (`dual` mode):**
   When both displays must be active simultaneously, USM first enables both
   at a safe low resolution (1024x768) to clear the bandwidth bottleneck,
   then applies a second pass to set the external display to its target
   resolution.

3. **Fail-Safe Rollback (Black Screen Prevention):**
   If `cmd_screen_ext` or `cmd_screen_dual` fails to activate the target
   display, USM falls back to `cmd_screen_int` to restore an internal-only
   working state. This guarantees the system never enters an unrecoverable
   dual-black state.

4. **Manual Screen Control (`screen-on` / `screen-off`):**
   USM exposes commands to explicitly turn screens off (`$SCREEN_ENABLED_NO`)
   or on. When executing `screen-on`, USM queries the Wayland compositor
   (`wlr-randr`) for active outputs to guarantee state consistency, and
   delegates to the appropriate switching strategy (ext, dual, or int) based
   on hardware presence and `USM_MODE`.

### F. Custom Execution Hooks

USM supports external script execution for user-defined actions. Upon
completing the display setup, USM checks for the existence of `hook-plug.sh`
or `hook-unplug.sh`. If executable, these scripts are triggered in the
background to prevent blocking the main event loop.

### G. HDMI Audio & Kernel Crash Prevention

The Raspberry Pi OS `vc4-hdmi` driver is known to cause kernel panics
when a display is hotplugged while the audio subsystem (PipeWire) holds
the audio device active. To prevent these fatal crashes, USM introduces
an asynchronous audio management layer.

1. **Async Initialization**: On startup, USM launches a background
   process (`init_hdmi_audio_default_async`) that waits up to 10 seconds
   for PipeWire to initialize. Once ready, it automatically applies the
   safe state defined by `USM_HDMI_AUDIO_DEFAULT_STATE` (defaulting to
   `"off"`). This stops the kernel from crashing during boot or hotplugs.
2. **Dynamic Command Switching**: Instead of using raw `pw-cli` commands,
   users can seamlessly toggle the Digital Stereo profile on the fly.
   Running `usm hdmi-audio-on` safely enables audio for media consumption,
   and `usm hdmi-audio-off` disables it before unplugging the display.

### H. Wayland-Only Power Control, `libliftoff` Safety & `kanshi` Isolation

On Raspberry Pi CM5, `DSI-2` (`card0`, `drm-rp1-dsi`) and `HDMI-A-1` (`card2`,
`vc4`) live on separate DRM devices. Writing out-of-band values to
`card*-DSI-2/status` or `fb0/blank` desynchronizes kernel CRTC vblank state
from `wlroots`/`libliftoff0` (`0.5.0-1.1+rpt6` site `0x333c`), causing a
permanent `drmCrtcGetSequence: EINVAL -> EPERM` CRTC deadlock until `labwc`
restarts. Conversely, the `panel-cwu50` kernel driver automatically toggles
`bl_power` (`4` OFF / `0` ON) on `wlr-randr --output DSI-2 --off/--on` while
preserving user brightness, keeping UPM battery powersave active.

1. **Zero Out-of-Band DRM/fb0 Writes**: USM controls displays solely via
   `wlr-randr` and targeted `wlopm` (external only) and never forces
   `DSI-2/status`, `fb0/blank`, or `HDMI-A-1/status=off` (preserving HPD).
   Manual panel recovery remains available via `usm screen-reset`.
2. **Runtime `kanshi` Isolation**: Raspberry Pi OS Trixie starts
   `/usr/bin/kanshi` from `/etc/xdg/labwc/autostart`, which races with USM on
   hotplug and mode switches. `cmd_monitor()` synchronously stops the current
   user's `kanshi` (polling up to 1s) after `wait_for_compositor` and before
   initial display reconciliation without altering `/etc/xdg/labwc/autostart`
   or `~/.config/kanshi/config`; `cmd_status()` reports `kanshi` state.
3. **Config Validation Matrix (`usm_validate_config`)**:
   - **Fail-closed (exit 1 on active commands)**: invalid `USM_MODE`,
     `USM_HDMI_IDLE_MODE`, `USM_HDMI_AUDIO_DEFAULT_STATE`, boolean keys, or
     non-decimal/leading-zero timeouts (`^(0|[1-9][0-9]*)$`). Diagnostic,
     stop, and recovery commands (`status`, `stop`, `version`, `read-conf`,
     `hw_status`, `screen-reset`) warn on `stderr` without blocking.
     `SIGHUP` (`reload_config`) pre-validates in a subshell before mutating
     live daemon globals.
   - **Warn-only (`stderr`)**: `SCREENSAVER_TIMEOUT > 0` with empty `CMD`,
     `SCREENSAVER_TIMEOUT >= SCREEN_OFF_TIMEOUT`, `HDMI_AUDIO="on"`,
     `USM_HDMI_IDLE_MODE="enable"`, and deprecated legacy keys (which are
     mapped/ignored safely for backward compatibility).

### I. Hardware Status Diagnostics

To assist with troubleshooting display issues, USM provides a dedicated
`hw_status` command. This diagnostic tool queries the Linux `sysfs` directly
to aggregate and report the real-time hardware state for both the internal
and external displays. It includes the DRM connection status, Panel Driver
loading state, Backlight power/brightness values, and the Framebuffer blank
and running states, giving users deep visibility into the underlying hardware
outside of Wayland's software state.

---


### Custom Hooks Architecture
USM exposes a lightweight hooking mechanism. By placing shell scripts in
`~/.config/usm/hooks/`, users can hook into four distinct lifecycle phases:
1.  **Daemon Start** (`usm_hook_usm_start.sh`)
2.  **Daemon Stop/Exit** (`usm_hook_usm_stop.sh`)
3.  **Hardware Plug** (`usm_hook_hdmi_plug.sh`)
4.  **Hardware Unplug** (`usm_hook_hdmi_unplug.sh`)

These scripts run synchronously and block the main event loop during execution.
Users should ensure hook scripts return quickly to avoid obstructing the main
(`dbus-monitor`/`udevadm`) event loop with slow user code.
*Note: The `make install` (or `install.sh`) script automatically grants
`chmod +x` execution permissions to these template scripts when copying them to
the user's config directory.*

### Swayidle Lifecycle Management
Swayidle logic adheres to the Single Responsibility Principle (SRP):
*   **Dedicated Idle Control (`cmd_idle_off` / `cmd_idle_on`)**: Silently
    sleeps active outputs — external HDMI via targeted `wlopm --off`
    (never wildcard `*`) and internal `DSI-2` via `wlr-randr` + `bl_power=4`
    for UPM powersave — persisting `ext`/`int`/`dual` in
    `$USM_RUN_DIR/idle_off.lock`. While external idle-off is active,
    `handle_event_udev` ignores transient DRM `change` events (HPD drop/bounce
    on DPMS). On resume, `cmd_idle_on` reconciles real state: waking active
    HDMI via `wlopm --on`, silently re-enabling `Enabled: no` HDMI via
    `cmd_screen_ext`/`cmd_screen_dual --silent`, or falling back to
    `cmd_screen_int --silent` + `$USM_RUN_DIR/state_dirty` if unplugged.
*   **Manual Power Key & External Wake Guard (`cmd_screen_switch`)**:
    Supports turning off both internal and external/dual displays. Manual
    screen-off pauses `swayidle` and writes `$USM_RUN_DIR/manual_off.lock`
    (so screensavers do not run while the screen is off); wake, hotplug, or
    suspend/resume clears the lock and restores `swayidle`. If an external app
    wakes a display, `_reconcile_external_wake` clears stale locks.
*   **Cross-Process Serialization (`_with_display_lock`)**: Display and sysfs
    mutations across `monitor`, `idle-off`/`idle-on`, and `screen-switch` are
    serialized via `flock` on `$USM_RUN_DIR/usm_display.lock`.
*   **Managed Autostart Block & Config Builder**: `install.sh` wraps USM
    swayidle entries in `# === USM Swayidle Config Start/End ===` markers
    (backing up `wlopm` with `# [USM backup] `, leaving custom configs
    untouched, and restoring backups on `usm-uninstall`). `cmd_start_swayidle`
    dynamically builds 3-stage `swayidle` args from `usm.conf` and both
    `cmd_start_swayidle` / `cmd_stop_swayidle` poll up to 1s to prevent
    restart race conditions.
*   **HDMI Idle Policy & Startup Sync (`USM_HDMI_IDLE_MODE`)**:
    - `"no-screen-off"` (default): omits Stage 2 `idle-off`/`idle-on` while
      HDMI is connected while keeping Stage 1 screensaver.
    - `"disable"`: stops `swayidle` while HDMI is connected and restores it on
      disconnect/exit (`manage_swayidle`, `cmd_start_swayidle`,
      `cleanup_on_exit`).
    - `"enable"`: keeps normal Stage 2 screen-off even when HDMI is connected.
    On `cmd_monitor` startup (`usm restart`), `_sync_usm_swayidle_on_startup`
    restarts USM-managed `swayidle` once so edited `usm.conf` idle settings
    always apply. `manage_swayidle` restarts USM-managed swayidle on HDMI
    state change via `_restart_swayidle_on_hdmi_change` (waking HDMI and
    clearing `idle_off.lock` first); custom swayidle configs are never
    modified.

### Automated Sandbox Testing Architecture

USM includes a zero-dependency pure-Bash sandbox test suite under `tests/`
(all files kept `0644`, executed via `bash tests/run_tests.sh`).
`run_tests.sh` runs `bash -n`, `shellcheck`, `<= 80 chars/line` checks, and
every suite in `tests/cases/test_*.sh`. `tests/lib/` isolates `HOME`,
`XDG_RUNTIME_DIR`, `USM_RUN_DIR_OVERRIDE`, and `USM_SYSFS_ROOT`;
`tests/mocks/` provides 14 upstream-aligned mocks (including `wlopm *`
wildcard guardrail, `DSI-2` DRM/fb0 poison detector, `panel-cwu50` driver
`bl_power` sync, `kanshi` process state, and `journalctl` stub);
`tests/fixtures/` supplies 3 hardware profiles
(HP E27u G4, generic 1080p, DSI-only).

*   **`test_wlr_randr_args.sh`**:
    *   `NOOP-1` pre-cleanup precedes `DSI-2 --on`; `--off` omits `--mode`,
        `--transform`, and `--pos`.
    *   Generic 1080p monitor uses `--preferred` when `USM_EXT_RES=""` (and
        omits `--preferred` safely if EDID has no `(preferred)` mode).
    *   Explicit `USM_EXT_RES` is honored in both `screen-ext` and
        `screen-dual`; `screen-dual` Stage 2 restores preferred `2560x1440`
        after Stage 1 `1024x768`.
*   **`test_hw_sequencing.sh`**:
    *   Verifies zero out-of-band `sudo tee` writes to `DSI-2/status`,
        `fb0/blank`, or `bl_power` across `ext -> int` and `int -> ext`.
    *   Verifies driver-managed `bl_power` transitions (`0 <-> 4`), user
        brightness preservation, and intact HDMI/DSI DRM `connected` state.
*   **`test_lock_and_state.sh`**:
    *   Monitor startup wakes HDMI DPMS and clears stale `ext`
        `idle_off.lock`; live HDMI hotplug clears `int` lock and enables
        HDMI.
    *   Failed startup switch logs error without hitting startup skip.
    *   Boot with HDMI active hits silent-boot fast-bypass (zero
        `wlr-randr --output`, zero `notify-send`, HDMI audio `off`).
    *   Boot with both screens active in `single` mode disables `DSI-2` and
        powers off backlight; `wait_for_compositor` waits for Wayland.
    *   Monitor startup syncs USM-managed `swayidle` with updated `usm.conf`
        when `USM_HDMI_IDLE_MODE="enable"`, while leaving custom non-USM
        `swayidle` configs untouched.
*   **`test_issue01_repro.sh`**:
    *   `idle-off` is silent and writes `ext` lock; `idle-on` re-enables
        `Enabled: no` HDMI after HPD drop/bounce.
    *   `USM_HDMI_IDLE_MODE="no-screen-off"` keeps Stage 1 screensaver and
        omits Stage 2 `idle-off`.
*   **`test_plan2_ext_screen_off.sh` (T1–T8)**:
    *   T1: Live daemon ignores HPD disconnect during ext `idle-off`;
        `idle-on` silently re-enables `Enabled: no` HDMI.
    *   T2: Physical HDMI unplug during ext `idle-off` -> `idle-on`
        silently recovers `DSI-2` and marks `state_dirty`.
    *   T3/T5: Ext Power Key pauses `swayidle` and turns off HDMI; 2nd press
        restores both; `wlopm --off` failure rolls back locks & `swayidle`.
    *   T4: Int Power Key pauses `swayidle`; live HDMI hotplug clears
        `manual_off.lock` and restores `swayidle`.
    *   T6/T7: External app waking HDMI or `DSI-2` clears stale locks
        (1 Power Key press turns HDMI off; live udev restores `swayidle`).
    *   T8: Ext Power Key off -> live suspend/resume clears both locks and
        restores `swayidle`.
*   **`test_plan2_edge_cases.sh` (T9–T22)**:
    *   T9–T11: `dual` mode `idle-off`/`idle-on` (incl. `Enabled: no`
        recovery), Power Key pause/restore, and unplug recovery to `DSI-2`
        + `state_dirty`.
    *   T12–T13: `USM_HDMI_IDLE_MODE="disable"` and default `usm.conf`
        never falsely start `swayidle` on HDMI wake/rollback.
    *   T14–T16: `wlr-randr` failure preserves `idle_off.lock`; missing
        `wlopm` rolls back cleanly; `cmd_screen_ext --silent` fallback stays
        silent.
    *   T17–T19: `wlopm *` wildcard guardrail, `state_dirty` live replug
        round-trip, and `usm_display.lock` (`flock`) serialization.
    *   T20–T22: Clean 1st-attempt `DSI-2` wake in `idle-on` and
        `screen-dual` without DRM poisoning; `exec_wlr_randr` retries up to
        3 times and preserves `idle_off.lock` on persistent failure.
*   **`test_config_and_guards.sh` (C1–C6)**:
    *   C1: 2x `screen-dual <-> screen-ext` cycles never poison DSI DRM/fb0
        even when legacy `USM_ENABLE_HW_POWER_CONTROL="true"` is present.
    *   C2: `cmd_monitor()` stops `kanshi` before first display mutation;
        `cmd_status()` reports `kanshi` running/stopped status.
    *   C3–C4: `usm_validate_config` fail-closed matrix (incl. octal `"08"`
        guard), diagnostic command exemption, and `SIGHUP` subshell guard.
    *   C5–C6: Warn-only risk matrix and legacy config backward compatibility.

### Manual On-Device Test Suite (`tests/manual/`)

Because sandbox mocks cannot validate real `panel-cwu50` / `vc4` kernel
drivers or physical monitor HPD behavior, USM provides an interactive
on-device suite under `tests/manual/` (all `0644`, linted by `run_tests.sh`
but never auto-executed). Every script sources `tests/manual/lib_watchdog.sh`,
which:
- Writes a timestamped log in the same folder
  (`tests/manual/<name>_YYYYMMDD_HHMMSS.log`).
- Arms a 120-second safety reboot timer with a random 4-digit PIN cancel
  (preventing permanent blackout lockouts) and prints an explicit cancellation
  notice on every exit path (PIN, `Ctrl+C`, or error).
- Never modifies `~/.config/usm/usm.conf`; tests needing temporary settings
  copy a throwaway config to `/tmp` via `USM_CONF_FILE` and clean up on exit.

Run individually on a real uConsole CM5 with `bash tests/manual/<script>`:
- **`01_service_and_swayidle_check.sh`**: Read-only preflight (`usm.service`,
  `kanshi` stopped, `swayidle` args, `wlr-randr`).
- **`02_hdmi_hotplug_cycles.sh`**: 2 full HDMI hotplug cycles (unplug ->
  `DSI-2` -> replug -> `HDMI-A-1`).
- **`03_int_idle_off_on.sh`**: Internal `DSI-2` `idle-off` -> 5s -> `idle-on`
  wake and retry verification.
- **`04_ext_idle_auto_off.sh`** *(optional)*: External HDMI 30s `swayidle`
  auto screen-off & wake (depends on monitor OSD Auto-Switch Input).
- **`05_ext_off_unplug_hdmi.sh`**: External Power Key off -> unplug HDMI ->
  wake internal `DSI-2` -> replug HDMI (`state_dirty`).
- **`06_ext_power_key_swayidle.sh`**: External Power Key off/on verifying
  `swayidle` pauses while off and restores on wake.
- **`07_int_off_plug_hdmi.sh`**: Internal Power Key off -> plug HDMI directly
  -> auto-switch and restore `swayidle`.
- **`08_suspend_resume.sh`**: Power Key off -> `systemctl suspend` -> resume
  (auto-prints `[SKIP]` on CM5 kernels that do not support S3 `mem` suspend).
- **`09_external_app_wake_guard.sh`**: External app runs `wlopm --on` while
  off -> single Power Key press turns HDMI off cleanly.
- **`10_dual_mode_power_key.sh`**: Temporary `USM_MODE="dual"` switch + Power
  Key off/on + restore `single` mode.
- **`11_dual_ext_stress.sh`**: 2x `screen-dual <-> screen-ext` stress test +
  asserts zero `libliftoff`/`Swapchain` errors in `~/.xsession-errors`.

Two non-scriptable checks remain manual-only: **booting with HDMI plugged
in** (verify silent boot with `DSI-2` dark) and **`usm-uninstall`
regression** (verify `autostart` backup restore and `usm.service` removal).

### Upstream Source References

For verifying Wayland protocol, output power, and compositor behavior:
- **wlr-randr** (`zwlr_output_management_v1` client):
  https://gitlab.freedesktop.org/emersion/wlr-randr
- **wlopm** (`zwlr_output_power_management_v1` client):
  https://git.sr.ht/~leon_plickat/wlopm
- **wlr-protocols** (`wlr-output-management` / `wlr-output-power-management`):
  https://gitlab.freedesktop.org/wlroots/wlr-protocols
- **labwc** (Raspberry Pi OS Trixie Wayland compositor):
  https://github.com/labwc/labwc
- **wlroots** (DRM backend & output management implementation):
  https://gitlab.freedesktop.org/wlroots/wlroots
- **libliftoff** (DRM KMS plane allocation library used by wlroots):
  https://gitlab.freedesktop.org/emersion/libliftoff

# 系統架構與設計文件 (Traditional Chinese)

本文件說明 uConsole Screen Manager (USM) 的底層技術設計與邏輯，
概述 USM 如何在不使用輪詢機制的狀況下，與 Linux 核心及 Wayland
合成器進行互動。

## 1. 設計目標

uConsole Screen Manager (USM) 專為在 Raspberry Pi OS Trixie (Wayland /
Labwc) 環境下動態管理外接螢幕所設計。它完全依賴即時的硬體事件監聽機制，
在不依賴背景持續輪詢的情況下，實現無縫的顯示輸出切換。

## 2. 系統架構圖

USM 同時監聽兩個事件來源，並將所有事件統一送入 `usm-cli.sh`
的單一處理迴圈。

```text
+------------------+   +---------------------------+
| Linux 核心        |   | udevadm monitor           |
| (DRM 子系統)      |-->| (HDMI 插拔事件)            |--+
+------------------+   +---------------------------+  |
                                                      | 事件
+------------------+   +---------------------------+  |
| logind (systemd) |-->| dbus-monitor              |--+
| (PrepareForSleep)|   | (休眠/喚醒訊號)             |  |
+------------------+   +---------------------------+  |
                                                      v
                                             +------------------+
                                             | usm-cli.sh       |
                                             | (cmd_monitor)    |
                                             +------------------+
                                                      |
                                                      | 1. 驗證 EDID 連線
                                                      | 2. 檢查冪等性狀態
                                                      | 3. 螢幕切換策略
                                                      v
                                             +--------------------+
                                             | Wayland 合成器      |
                                             | (wlr-randr)        |
                                             +--------------------+
                                                      |
                                                      | 4. 觸發擴充掛鉤
                                                      v
                                             +--------------------+
                                             | hook-plug.sh /     |
                                             | hook-unplug.sh     |
                                             +--------------------+
```

## 3. 核心設計原則

### A. 零 CPU 消耗 (事件驅動)

USM 在單一 `while read` 迴圈中同時監聽兩個事件來源：

- `udevadm monitor --subsystem=drm`：阻塞等待核心的 DRM 硬體
  變更事件，用於 HDMI 插拔偵測。
- `dbus-monitor`：訂閱 logind 的 `PrepareForSleep` 訊號，
  用於處理系統休眠與喚醒。

兩個來源以平行子進程方式執行。當所有硬體狀態靜止時，
USM 的 CPU 佔用率為 0%。

### B. 狀態防抖與硬體二次驗證 (Debounce & Re-verify)

當螢幕進入休眠省電模式 (DPMS) 時，常會主動切斷熱插拔偵測 (HPD)
訊號，導致 Linux 核心發出錯誤的「斷線」事件。USM 採用兩段式防抖
策略防止無效切換：

1. 若事件到達時距上次處理事件不足 DEBOUNCE_SEC 秒，立即捨棄該
   事件，防止事件風暴導致連鎖防抖等待。
2. 否則，USM 強制等待 DEBOUNCE_SEC 秒讓硬體狀態穩定。
3. 等待結束後，USM 主動重新讀取底層硬體的 DRM 狀態。
4. 若狀態與前次相同（即假斷線後迅速恢復），則安全忽略該事件。

### C. 冪等性與狀態匹配 (快速跳過)

在執行任何顯示操作前，USM 會主動向 Wayland 合成器查詢當前的輸出
狀態 (`Enabled: yes/no`)。若系統已處於預期狀態，USM 將直接跳過執
行。這項設計確保了開機時的靜默啟動 (Silent Boot)，並防止重複觸發
導致的畫面閃爍。

### D. EDID 防呆機制

系統喚醒時常有假訊號，僅檢查 HDMI 狀態是否為 `connected` 並不可
靠。USM 會驗證 EDID 檔案大小，確保大於 0 位元組時才確認為有效實體
連線，避免盲目對未連接的端子下達設定指令。

### E. 顯示模式切換策略 (3 Modes)

Raspberry Pi CM4 的 VC4 KMS 驅動在面臨原子提交 (Atomic Commit) 時，
常因瞬間的 CMA 記憶體頻寬耗盡而拒絕套用設定。USM 依據需求採用以下
策略：

1. **直接切換搭配 Fallback - 適用 `ext` 與 `int` 單螢幕模式**：
   USM 先以單一 `wlr-randr` 指令嘗試直接切換。若成功則結束。若驅
   動拒絕，進入 fallback 序列：關閉所有螢幕，短暫等待，再啟用目標
   螢幕。避免同時操作雙螢幕的狀態衝突與頻寬崩潰。

2. **低解析度同步 (Low-res Sync) - 適用 `dual` 雙螢幕模式**：
   必須同時亮起雙螢幕時，先以低解析度 (1024x768) 同時啟用雙螢幕以
   清空頻寬瓶頸，再對外接螢幕套用目標高解析度。

3. **黑屏防護機制 (Fail-Safe Rollback)**：
   若 `cmd_screen_ext` 或 `cmd_screen_dual` 設定失敗，USM 自動
   fallback 至 `cmd_screen_int`，確保內螢幕可用，防止系統陷入雙重
   黑屏狀態。

4. **手動螢幕控制 (`screen-on` / `screen-off`)**：
   提供明確的指令讓使用者強制關閉 (`screen-off`) 或開啟 (`screen-on`)
   螢幕。在執行 `screen-on` 時，USM 向 Wayland 合成器 (`wlr-randr`)
   查詢目前偵測到的實體螢幕，並依據結果與 `USM_MODE` 分派至適當的切換
   策略 (ext, dual, 或 int)。

### F. 自訂執行掛鉤 (Hooks)

USM 允許使用者透過外部腳本執行自訂操作。在完成螢幕切換後，
USM 會檢查 `hook-plug.sh` 或 `hook-unplug.sh` 是否存在。
若具備執行權限，腳本會於背景觸發，確保不阻塞主監聽迴圈。

### G. HDMI 音效管理與核心崩潰防護 (Audio & Crash Prevention)

Raspberry Pi OS 的 `vc4-hdmi` 驅動存在一個已知的硬體缺陷：當 PipeWire 音效
子系統正佔用 HDMI 音訊設備時，進行螢幕熱插拔極易引發核心崩潰 (Kernel Panic)。
為了防堵這個致命錯誤，USM 導入了一套非同步的音效管理防護層。

1. **非同步初始化 (Async Initialization)**：開機時，USM 會啟動一個背景進程
   (`init_hdmi_audio_default_async`)，聰明地等待最高 10 秒直到 PipeWire
   就緒。接著，它會自動套用設定檔中的安全預設值 (預設為 `"off"`)，從源頭
   徹底根除開機與熱插拔時的當機風險。
2. **動態指令切換 (Dynamic Command Switching)**：使用者無須學習複雜的底層
   `pw-cli` 操作。當需要享受影音時，只需執行 `usm hdmi-audio-on` 即可安全
   喚醒音效 (Digital Stereo)；而在拔除螢幕前，執行 `usm hdmi-audio-off`
   即可安全釋放佔用，保障系統穩定。

### H. Wayland 單一控制權、`libliftoff` 防死鎖與 `kanshi` 隔離

在 Raspberry Pi CM5 上，`DSI-2`（`card0`、`drm-rp1-dsi`）與 `HDMI-A-1`
（`card2`、`vc4`）分屬兩張獨立 DRM 卡。繞過合成器直接寫入
`card*-DSI-2/status` 或 `fb0/blank` 會導致 kernel CRTC vblank 與
`wlroots`/`libliftoff0`（`0.5.0-1.1+rpt6` 位址 `0x333c`）脫鉤，引發永久性
`drmCrtcGetSequence: EINVAL -> EPERM` CRTC 死鎖直到重啟 `labwc`。相對地，
`panel-cwu50` 驅動在 `wlr-randr --output DSI-2 --off/--on` 時本身即會自動
切換 `bl_power`（`4` 關 / `0` 開）並保留使用者亮度，UPM 電池省電完全生效。

1. **零帶外 DRM/fb0 寫入**：USM 僅透過 `wlr-randr` 與具名 `wlopm`（限外接）
   控制輸出，絕不寫入 `DSI-2/status`、`fb0/blank` 或 `HDMI-A-1/status=off`
   （永久保留 HPD）；手動救援仍由 `usm screen-reset` 提供。
2. **執行期自動停用 `kanshi`**：Raspberry Pi OS Trixie 會透過
   `/etc/xdg/labwc/autostart` 預設啟動 `/usr/bin/kanshi` 與 USM 搶奪設定。
   `cmd_monitor()` 於 `wait_for_compositor` 後、首次套用顯示設定前同步停用
   當前使用者的 `kanshi`（輪詢最多 1 秒），不更動系統 `autostart` 與
   `~/.config/kanshi/config`；`cmd_status()` 會回報 `kanshi` 狀態。
3. **設定檔分級驗證（`usm_validate_config`）**：
   - **Fail-closed（主動指令回傳 exit 1）**：攔截非法 `USM_MODE`、
     `USM_HDMI_IDLE_MODE`、`USM_HDMI_AUDIO_DEFAULT_STATE`、布林鍵與含前導零
     的非十進位逾時（`^(0|[1-9][0-9]*)$`）。診斷/停止/救援指令（`status`、
     `stop`、`version`、`read-conf`、`hw_status`、`screen-reset`）改為只印
     `stderr` 警告不阻擋；`SIGHUP`（`reload_config`）先於 subshell 預檢，
     避免壞設定覆蓋或打死背景 daemon。
   - **Warn-only（`stderr`）**：螢幕保護逾時未設指令、螢幕保護逾時大於等於
     熄屏逾時、`HDMI_AUDIO="on"`、`USM_HDMI_IDLE_MODE="enable"` 與非空棄用
     舊鍵（向後相容轉換或安全忽略）。

### I. 硬體狀態診斷 (Hardware Status Diagnostics)

為協助排解顯示輸出問題，USM 提供專屬的 `hw_status` 診斷指令。此工具會直接向
Linux `sysfs` 查詢並彙整內外螢幕的即時硬體狀態。其回報內容涵蓋了 DRM 連線狀態、
面板驅動 (Panel Driver) 載入情形、背光 (Backlight) 電源與亮度數值，以及 Framebuffer
的休眠與運作狀態。這項機制讓使用者在 Wayland 軟體層之外，能深入透視底層硬體的
真實運作情況。

### 自定義腳本架構 (Custom Hooks Architecture)
USM 提供輕量級的 Hook 機制。使用者只需將 shell 腳本放置於
`~/.config/usm/hooks/` 中，即可介入以下四個生命週期階段：
1.  **守護行程啟動 (Daemon Start)** (`usm_hook_usm_start.sh`)
2.  **守護行程停止/退出 (Daemon Stop/Exit)** (`usm_hook_usm_stop.sh`)
3.  **硬體插入 (Hardware Plug)** (`usm_hook_hdmi_plug.sh`)
4.  **硬體拔除 (Hardware Unplug)** (`usm_hook_hdmi_unplug.sh`)

所有 Hook 腳本皆在背景以非阻塞（Non-blocking）模式執行，確保
`dbus-monitor`/`udevadm` 的主事件迴圈不會被耗時的使用者程式碼所阻塞。
*備註：在執行安裝腳本 (`install.sh`) 時，系統會自動賦予複製到使用者設定檔目
錄下的樣板腳本 `chmod +x` 的執行權限。*

### Swayidle 生命週期管理
Swayidle 邏輯嚴格遵循單一責任原則（SRP）：
*   **專用閒置控制（`cmd_idle_off` / `cmd_idle_on`）**：靜默休眠作用中螢幕
    ——外接 HDMI 採具名 `wlopm --off`（嚴禁萬用字元 `*`），內建 `DSI-2` 採
    `wlr-randr` + `bl_power=4` 連動 UPM 省電——並於
    `$USM_RUN_DIR/idle_off.lock` 記錄 `ext`/`int`/`dual`。外接熄屏期間，
    `handle_event_udev` 會忽略 DPMS 引發的暫時性 DRM `change`（HPD 掉線
    回彈）；喚醒時 `cmd_idle_on` 依實體狀態對帳：優先以 `wlopm --on` 喚醒，
    若 HDMI 掉成 `Enabled: no` 則以 `cmd_screen_ext`/`cmd_screen_dual
    --silent` 靜默重啟，若已實體拔除則切回 `cmd_screen_int --silent` 並標記
    `$USM_RUN_DIR/state_dirty`。
*   **電源鍵手動熄屏與外部喚醒防呆（`cmd_screen_switch`）**：支援內建與外接
    /雙螢幕手動熄屏；熄屏期間暫停 `swayidle` 並寫入
    `$USM_RUN_DIR/manual_off.lock`（避免熄屏後背景觸發螢幕保護），待喚醒、
    熱插拔或休眠恢復後自動清鎖並重啟 `swayidle`。若外部程式點亮螢幕，
    `_reconcile_external_wake` 會自動清理過期鎖。
*   **跨行程互斥鎖（`_with_display_lock`）**：`monitor`、`idle-off`/
    `idle-on` 與 `screen-switch` 的顯示與 sysfs 操作皆以
    `$USM_RUN_DIR/usm_display.lock`（`flock`）串行化。
*   **受管區塊與設定組裝**：`install.sh` 以 `# === USM Swayidle Config`
    `Start/End ===` 標記管理 `autostart`（自動以 `# [USM backup] ` 備份遷移
    `wlopm`、保留非 `wlopm` 自訂設定，反安裝時自動還原）。
    `cmd_start_swayidle` 依 `usm.conf` 動態組裝三階段 `swayidle` 參數，且與
    `cmd_stop_swayidle` 皆具備最多 1 秒輪詢防範重啟競爭。
*   **HDMI 閒置策略與啟動同步（`USM_HDMI_IDLE_MODE`）**：
    - `"no-screen-off"`（預設）：連接 HDMI 期間省略階段 2 `idle-off`/`idle-on`
      逾時，保留階段 1 螢幕保護。
    - `"disable"`：連接 HDMI 期間停用整個 `swayidle`，拔除或服務退出時恢復
      （`manage_swayidle`、`cmd_start_swayidle`、`cleanup_on_exit`）。
    - `"enable"`：連接 HDMI 期間維持正常階段 2 熄屏。
    `cmd_monitor` 啟動（`usm restart`）時，`_sync_usm_swayidle_on_startup`
    會先同步重啟一次 USM 管理的 `swayidle`，確保任何 `usm.conf` 閒置修改皆
    立即生效。HDMI 狀態改變時，`manage_swayidle` 經
    `_restart_swayidle_on_hdmi_change` 重啟 USM 管理的 swayidle（先喚醒 HDMI
    並清除 `idle_off.lock`）；自訂 swayidle 設定絕不修改。

### 自動化沙盒測試架構

USM 於 `tests/` 提供零外部相依的純 Bash 沙盒測試套件（所有檔案維持
`0644`，以 `bash tests/run_tests.sh` 執行）。`run_tests.sh` 依序檢查
`bash -n`、`shellcheck`、`<= 80 chars/line`，並執行全部
`tests/cases/test_*.sh`。`tests/lib/` 隔離 `HOME`、`XDG_RUNTIME_DIR`、
`USM_RUN_DIR_OVERRIDE` 與 `USM_SYSFS_ROOT`；`tests/mocks/` 提供 14 個
對齊上游行為的 mock（含 `wlopm *` 防呆、`DSI-2` DRM/fb0 毒化偵測、
`panel-cwu50` 驅動 `bl_power` 同步、`kanshi` 狀態與 `journalctl` stub）；
`tests/fixtures/` 提供 3 組硬體樣板（HP E27u G4、通用 1080p、純內建 DSI）。

*   **`test_wlr_randr_args.sh`**：
    *   `NOOP-1` pre-cleanup 先於 `DSI-2 --on`，且 `--off` 不夾帶
        `--mode`/`--transform`/`--pos`。
    *   通用 1080p 螢幕在 `USM_EXT_RES=""` 時帶 `--preferred`（若 EDID
        無 `(preferred)` 標記則安全省略）。
    *   指定 `USM_EXT_RES` 於 `screen-ext` 與 `screen-dual` 皆生效，且
        `screen-dual` Stage 2 會由 `1024x768` 回復原生 `2560x1440`。
*   **`test_hw_sequencing.sh`**：
    *   驗證 `ext -> int` 與 `int -> ext` 過程零帶外 `sudo tee` 寫入
        `DSI-2/status`、`fb0/blank` 或 `bl_power`。
    *   驗證驅動自動同步 `bl_power`（`0 <-> 4`）、保留使用者亮度，且 HDMI
        與 DSI DRM 皆維持 `connected`。
*   **`test_lock_and_state.sh`**：
    *   `monitor` 啟動喚醒殘留 `ext` `idle_off.lock` 並清鎖；即時熱插拔
        HDMI 清除 `int` 鎖並啟用外接。
    *   啟動切換失敗記錄錯誤，不誤入啟動略過分支。
    *   插著 HDMI 靜默開機（命中 `Screen mode matches 'ext'`、零
        `wlr-randr --output` 與通知、HDMI 音效 `off`）。
    *   `single` 模式開機雙亮關閉 `DSI-2` 並斷背光；`wait_for_compositor`
        阻塞等待 Wayland 就緒。
    *   `monitor` 啟動時在 `USM_HDMI_IDLE_MODE="enable"` 下會以新版
        `usm.conf` 同步重啟 USM 管理的 `swayidle`，且絕不更動非 USM 自訂
        `swayidle` 設定。
*   **`test_issue01_repro.sh`**：
    *   `idle-off` 靜默寫入 `ext` 鎖；HPD 掉線變 `Enabled: no` 後，
        `idle-on` 重新啟用 HDMI。
    *   `USM_HDMI_IDLE_MODE="no-screen-off"` 保留 Stage 1 螢幕保護並省略
        Stage 2 `idle-off`。
*   **`test_plan2_ext_screen_off.sh`（T1–T8）**：
    *   T1：外接 `idle-off` 期間即時 daemon 忽略 HPD 斷線，`idle-on`
        靜默重啟 `Enabled: no` HDMI。
    *   T2：外接 `idle-off` 期間實體拔線，`idle-on` 靜默救回 `DSI-2`
        並設 `state_dirty`。
    *   T3/T5：外接電源鍵熄屏暫停 `swayidle`、二次按鍵恢復；`wlopm
        --off` 失敗回滾雙鎖與 `swayidle`。
    *   T4：內建電源鍵熄屏暫停 `swayidle`，即時插入 HDMI 清
        `manual_off.lock` 並恢復 `swayidle`。
    *   T6/T7：外部程式點亮 HDMI 或 `DSI-2` 自動清過期鎖（按一次電源鍵即
        熄屏、即時 udev 恢復 `swayidle`）。
    *   T8：外接電源鍵熄屏經即時 suspend/resume 清除雙鎖並恢復
        `swayidle`。
*   **`test_plan2_edge_cases.sh`（T9–T22）**：
    *   T9–T11：`dual` 模式 `idle-off`/`idle-on`（含 `Enabled: no`
        救回）、電源鍵開關與拔線救回 `DSI-2` + `state_dirty`。
    *   T12–T13：`USM_HDMI_IDLE_MODE="disable"` 與預設 `usm.conf` 在外接
        喚醒/回滾時絕不誤啟 `swayidle`。
    *   T14–T16：`wlr-randr` 失敗保留 `idle_off.lock`；缺 `wlopm` 安全
        回滾；`cmd_screen_ext --silent` fallback 零通知。
    *   T17–T19：`wlopm *` wildcard 防呆、`state_dirty` 即時插回閉環、
        `usm_display.lock`（`flock`）跨行程序列化。
    *   T20–T22：`idle-on` 與 `screen-dual` 在無 DRM 毒化下第 1 次即成功；
        `exec_wlr_randr` 保留 3 次重試並在持續失敗時保留 `idle_off.lock`。
*   **`test_config_and_guards.sh`（C1–C6）**：
    *   C1：連續 2 輪 `screen-dual <-> screen-ext`（含舊鍵殘留）零 DRM
        毒化、驅動自動 `bl_power=4` 且保留亮度。
    *   C2：`cmd_monitor()` 於首次切換前同步停用 `kanshi`；`cmd_status()`
        正確回報 `kanshi` 狀態。
    *   C3–C4：`usm_validate_config` Fail-closed 矩陣（含 `"08"` 八進位
        防護）、診斷指令豁免與 `SIGHUP` subshell 防崩潰保護。
    *   C5–C6：Warn-only 風險提示矩陣與舊版設定鍵向後相容。

### 實機人工測試套件（`tests/manual/`）

沙盒 mock 無法取代真實 `panel-cwu50` / `vc4` 核心驅動與實體螢幕 HPD 行為，
因此 USM 於 `tests/manual/` 提供互動式實機驗證套件（皆為 `0644`，納入
`run_tests.sh` 靜態語法/長度檢查但**絕不自動執行**）。各腳本共用
`tests/manual/lib_watchdog.sh`：
- 於同資料夾自動產生帶時間戳的紀錄檔（`tests/manual/<檔名>_時間.log`）。
- 內建 120 秒安全重開機看門狗與隨機 4 位 PIN 取消機制（防黑屏卡死），且
  **任何退出路徑**（PIN 通過、`Ctrl+C` 或錯誤退出）皆明確印出取消通知。
- 絕不修改 `~/.config/usm/usm.conf`；需要暫時設定的測項改以 `/tmp` 暫存檔
  搭配 `USM_CONF_FILE` 執行，退出時自動清理並還原 `swayidle`。

於實機執行 `bash tests/manual/<檔名>`：
- **`01_service_and_swayidle_check.sh`**：唯讀前檢（`usm.service`、
  `kanshi` 已停用、`swayidle` 參數、`wlr-randr`）。
- **`02_hdmi_hotplug_cycles.sh`**：連續 2 輪 HDMI 熱插拔切換測試。
- **`03_int_idle_off_on.sh`**：純內建 `DSI-2` `idle-off` -> 等 5 秒 ->
  `idle-on` 喚醒與重試驗證。
- **`04_ext_idle_auto_off.sh`** *(選測)*：外接 HDMI 30 秒 `swayidle` 自動
  熄屏與喚醒（視螢幕 OSD Auto-Switch Input 設定而定）。
- **`05_ext_off_unplug_hdmi.sh`**：外接電源鍵熄屏 -> 拔除 HDMI -> 喚醒內建
  `DSI-2` -> 插回 HDMI（`state_dirty`）。
- **`06_ext_power_key_swayidle.sh`**：外接電源鍵熄屏/喚醒，驗證熄屏期間
  `swayidle` 暫停、喚醒後恢復。
- **`07_int_off_plug_hdmi.sh`**：內建電源鍵熄屏 -> 直接插上 HDMI -> 自動切
  外接並恢復 `swayidle`。
- **`08_suspend_resume.sh`**：電源鍵熄屏 -> `systemctl suspend` -> 喚醒
  （於不支援 S3 休眠的 CM5 核心自動印出 `[SKIP]` 安全結束）。
- **`09_external_app_wake_guard.sh`**：外部程式 `wlopm --on` 點亮 HDMI 後，
  單按一次電源鍵即可直接熄屏。
- **`10_dual_mode_power_key.sh`**：暫切 `USM_MODE="dual"` 測試雙螢幕電源鍵
  熄屏/喚醒並自動還原 `single`。
- **`11_dual_ext_stress.sh`**：連續 2 輪 `screen-dual <-> screen-ext` 壓力
  切換並驗證 `~/.xsession-errors` 零 `libliftoff`/`Swapchain` 錯誤。

另有 2 項不適合做成日常腳本的項目維持手動檢查：**插著 HDMI 開機**（確認
靜默啟動且 `DSI-2` 保持關閉）與 **`usm-uninstall` 反安裝回歸**（確認還原
`autostart` 備份並移除 `usm.service`）。

### 上游開源程式碼參考

供查核 Wayland 協議、輸出電源管理與合成器底層行為：
- **wlr-randr** (`zwlr_output_management_v1` 客戶端)：
  https://gitlab.freedesktop.org/emersion/wlr-randr
- **wlopm** (`zwlr_output_power_management_v1` 客戶端)：
  https://git.sr.ht/~leon_plickat/wlopm
- **wlr-protocols** (`wlr-output-management` / `wlr-output-power-management`)：
  https://gitlab.freedesktop.org/wlroots/wlr-protocols
- **labwc** (Raspberry Pi OS Trixie Wayland 合成器)：
  https://github.com/labwc/labwc
- **wlroots** (DRM 後端與輸出管理實作)：
  https://gitlab.freedesktop.org/wlroots/wlroots
- **libliftoff** (wlroots 使用的 DRM KMS plane 配置函式庫)：
  https://gitlab.freedesktop.org/emersion/libliftoff
