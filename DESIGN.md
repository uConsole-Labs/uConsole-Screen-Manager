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

### H. Decoupled Hardware Power Control Layer

To prevent atomic commit race conditions between the Linux DRM subsystem and
the Wayland compositor (`wlr-randr`), USM enforces a strict 3-stage hardware
and software decoupling logic. This is controlled by the config flag
`USM_ENABLE_HW_POWER_CONTROL`:

1.  **Hardware ON (Pre-flight):** Before instructing Wayland to enable a screen,
    USM forces the DRM sysfs `status` to `detect` and wakes up the framebuffer
    (`fb0/blank=0`) and backlight (`bl_power=0`). This ensures the hardware is
    awake and ready to accept Wayland's configurations.
2.  **Software Switch:** Wayland (`wlr-randr`) takes control and attaches or
    detaches outputs safely without deadlocking the kernel.
3.  **Hardware OFF (Post-flight):** After Wayland successfully releases an
    output, USM manually cuts off power by setting the DRM `status` to `off`,
    blinding the framebuffer (`blank=1`), and dropping backlight PWM to `0`.

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
*   **Hardware & Exit Transitions**: `manage_swayidle` and `cleanup_on_exit`
    delegate to `cmd_start_swayidle` / `cmd_stop_swayidle` when
    `USM_HDMI_DISABLE_SWAYIDLE="true"`.
*   **HDMI Screen-Off Guard**: with `USM_HDMI_DISABLE_SCREEN_OFF="true"`
    (default), `cmd_start_swayidle` omits the Stage 2 `idle-off`/`idle-on`
    timeout while HDMI is connected. `manage_swayidle` restarts USM-managed
    swayidle on HDMI state change via `_restart_swayidle_on_hdmi_change`
    (waking HDMI and clearing `idle_off.lock` first); custom swayidle
    configs are never modified.

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

### H. 軟硬體解耦與實體電源控制 (Hardware Power Control Layer)

為了解決 Linux DRM 子系統與 Wayland 合成器 (`wlr-randr`) 之間搶奪控制權
而導致的 Deadlock (Atomic Commit Race Condition)，USM 導入了嚴格的三段
式解耦邏輯。此功能由設定檔中的 `USM_ENABLE_HW_POWER_CONTROL` 參數控制：

1.  **硬體先行喚醒 (Hardware ON)**：在指示 Wayland 啟用螢幕前，USM 會直接對
    sysfs 下達指令，將 DRM `status` 強制設為 `detect`，並喚醒 Framebuffer
    (`fb0/blank=0`) 與背光 (`bl_power=0`)，確保底層硬體處於 Ready 狀態。
2.  **軟體接管 (Software Switch)**：執行 `wlr-randr` 讓 Wayland 安全地掛載或
    釋放顯示資源。
3.  **硬體實體斷電 (Hardware OFF)**：在 Wayland 成功釋放該螢幕後，USM 才會將
    DRM `status` 設為 `off`、遮蔽 Framebuffer (`blank=1`) 並將背光亮度歸零，
    實現最深度的硬體省電。

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
*   **硬體轉換與服務終止**：當 `USM_HDMI_DISABLE_SWAYIDLE="true"` 時，
    `manage_swayidle` 與 `cleanup_on_exit` 委派給 `cmd_start_swayidle` 與
    `cmd_stop_swayidle`。
*   **HDMI 熄屏防護**：`USM_HDMI_DISABLE_SCREEN_OFF="true"`（預設）時，
    連接 HDMI 期間 `cmd_start_swayidle` 會省略階段 2 的
    `idle-off`/`idle-on` 逾時。HDMI 狀態改變時，`manage_swayidle` 經
    `_restart_swayidle_on_hdmi_change` 重啟 USM 管理的 swayidle（先喚醒 HDMI
    並清除 `idle_off.lock`）；自訂 swayidle 設定絕不修改。

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
