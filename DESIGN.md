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

USM uses a strictly one-way, event-driven data flow, delegating all complex
logic to the CLI executor.

```text
+---------------+      +-------------------+      +-----------------+
| Linux Kernel  |Event | udevadm (Monitor) |Wakes | usm-core.sh     |
| (DRM Subsys)  |----->| (Waits passively) |----->| (Entrypoint)    |
+---------------+      +-------------------+      +-----------------+
                                                         |
                                                         | Forwards to
                                                         v
                                                +-------------------+
                                                | usm-cli.sh        |
                                                | (Logic Executor)  |
                                                +-------------------+
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

USM utilizes `udevadm monitor --subsystem=drm`. This command blocks execution
until the kernel emits a hardware change event. When the HDMI state is
static, USM consumes exactly 0% CPU.

### B. State Debounce and Hardware Re-verification

Monitors entering power-saving sleep modes (DPMS) frequently drop the Hot Plug
Detect (HPD) signal, causing the Linux kernel to emit a false "disconnected"
event. To prevent ghost switching:
1. USM enforces a strict 5-second debounce window when an event is detected.
2. After the debounce period, USM actively re-reads the hardware DRM status.
3. If the state matches the previous state (i.e., a phantom disconnect), the
event is safely ignored.

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
CMA bandwidth exhaustion. USM handles this using a dual-track strategy with
a built-in fail-safe mechanism:

1. **Sequential Switching (`ext` and `int` modes):**
   When the target requires only one display, USM safely transitions by
   first turning off the old display before turning on the new one. This
   completely avoids the bandwidth bottlenecks of dual simultaneous activation.

2. **Low-res Sync (`dual` mode):**
   When both displays must be active simultaneously, USM temporarily forces
   both displays to low resolutions (720x1280 & 1024x768) to clear the
   bandwidth bottleneck, then reapplies the external display's high resolution.

3. **Fail-Safe Rollback (Black Screen Rescue):**
   If a display fails to activate during the transition (e.g., bad cable or
   Wayland rejection), USM aborts the operation and calls
   `rescue_internal_display` to forcefully awaken the internal DSI screen.
   This guarantees the system never enters an unrecoverable dual-black state.

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

USM 採用嚴格的單向、事件驅動資料流，並將所有複雜邏輯委派給 CLI 執行器。

```text
+---------------+      +-------------------+       +--------------+
| Linux 核心     | 事件 | udevadm (監聽器)    | 喚醒  | usm-core.sh  |
| (DRM 子系統)   |----->| (被動等待 0% CPU)   |----->| (服務進入點)  |
+---------------+      +-------------------+       +--------------+
                                                          |
                                                          | 轉發執行至
                                                          v
                                                 +-------------------+
                                                 | usm-cli.sh        |
                                                 | (主控邏輯腳本)      |
                                                 +-------------------+
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

USM 利用 `udevadm monitor --subsystem=drm` 進行監聽。此指令會阻塞
腳本執行，直到核心發出硬體變更事件。當 HDMI 狀態未改變時，
USM 的 CPU 佔用率為 0%。

### B. 狀態防抖與硬體二次驗證 (Debounce & Re-verify)

當螢幕進入休眠省電模式 (DPMS) 時，常會主動切斷熱插拔偵測 (HPD) 訊號，導致
Linux 核心發出錯誤的「斷線」事件。為了防止無效的切換行為：
1. USM 在接收到事件後，強制套用嚴格的 5 秒防抖等待期。
2. 等待期結束後，USM 會主動重新讀取底層硬體的 DRM 狀態。
3. 若狀態與前次相同（即假斷線後又迅速甦醒），則安全地忽略該次事件。

### C. 冪等性與狀態匹配 (快速跳過)

在執行任何顯示操作前，USM 會主動向 Wayland 合成器查詢當前的輸出狀態
(`Enabled: yes/no`)。若系統已處於預期狀態，USM 將直接跳過執行。
這項設計確保了開機時的靜默啟動 (Silent Boot)，並防止重複觸發導致的畫面閃爍。

### D. EDID 防呆機制

系統喚醒時常有假訊號，僅檢查 HDMI 狀態是否為 `connected` 並不可靠。
USM 會驗證 EDID 檔案大小，確保大於 0 位元組時才確認為有效實體連線，
避免盲目對未連接的端子下達設定指令。

### E. 顯示模式切換策略 (3 Modes)

Raspberry Pi CM4 的 VC4 KMS 驅動在面臨原子提交 (Atomic Commit) 時，常因瞬
間的 CMA 記憶體頻寬耗盡而拒絕套用設定。USM 依據單雙螢幕需求採用「雙軌策
略」，並配備自動黑屏救援機制 (Fail-Safe Rollback)：

1.  **循序切換 (Sequential Switching) - 適用 `ext` 與 `int` 單螢幕模式**：
    系統採用「先關閉舊螢幕，再開啟新螢幕」的安全順序，完全避免同時操作
    雙螢幕所帶來的狀態衝突與頻寬崩潰風險。
2.  **低解析度同步 (Low-res Sync) - 適用 `dual` 雙螢幕模式**：
    當必須同時亮起雙螢幕時，系統會先強制將雙螢幕分別設定為極低解析度
    (1024x768 與 720x1280) 以清空頻寬瓶頸，同步成功後再將外接螢幕提升至
    最終的高解析度。
3.  **黑屏救援機制 (Fail-Safe Rollback)**：
    在上述任何切換過程中，若目標螢幕設定失敗（如線材不良或 Wayland 拒
    絕套用），USM 會自動中斷操作，並呼叫 `rescue_internal_display` 函式
    強制喚醒內建 DSI 螢幕，防止系統陷入雙重黑屏的死機狀態。

### F. 自訂執行掛鉤 (Hooks)

USM 允許使用者透過外部腳本執行自訂操作。在完成螢幕切換後，
USM 會檢查 `hook-plug.sh` 或 `hook-unplug.sh` 是否存在。
若具備執行權限，腳本會於背景觸發，確保不阻塞主監聽迴圈。
