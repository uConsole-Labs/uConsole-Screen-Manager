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

### F. Custom Execution Hooks

USM supports external script execution for user-defined actions. Upon
completing the display setup, USM checks for the existence of `hook-plug.sh`
or `hook-unplug.sh`. If executable, these scripts are triggered in the
background to prevent blocking the main event loop.

---

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

### F. 自訂執行掛鉤 (Hooks)

USM 允許使用者透過外部腳本執行自訂操作。在完成螢幕切換後，
USM 會檢查 `hook-plug.sh` 或 `hook-unplug.sh` 是否存在。
若具備執行權限，腳本會於背景觸發，確保不阻塞主監聽迴圈。
