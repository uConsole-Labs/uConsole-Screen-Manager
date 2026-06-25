
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
                                                         | 3. HW Workaround
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

### B. Idempotence & State Matching (Fast-Bypass)

Before executing any display manipulation, USM actively probes the Wayland
compositor for the current output state (`Enabled: yes/no`). If the system
is already in the expected target state, USM safely bypasses the execution.
This guarantees silent boots and prevents screen flickering on redundant triggers.

### C. The EDID Fail-Safe Mechanism

Checking if the HDMI port status is `connected` is insufficient due to false
positives during system wake-up. USM verifies the size of the EDID file
(`/sys/class/drm/card*-HDMI-A-1/edid`). If the size is greater than 0, USM
confirms a valid physical connection before proceeding.

### D. Hardware Bandwidth Workaround (3-Step Sync)

The Raspberry Pi CM4's VC4 KMS driver often rejects atomic commits (e.g.,
simultaneously turning on a vertical DSI and turning off a 2K HDMI display)
due to momentary CMA bandwidth exhaustion. USM mitigates this hardware flaw
using an asymmetric switching strategy:

1. **Low-res Sync:** Temporarily forces both displays to low resolutions
(720x1280 & 1024x768) to clear the bandwidth bottleneck.
2. **Resolution Restore:** Reapplies the external display's preferred high
resolution.
3. **State Finalization:** Safely disables the unnecessary display output based
on the user's config mode.

### E. Custom Execution Hooks

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
                                                          | 3. 硬體頻寬除錯序列
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

### B. 冪等性與狀態匹配 (快速跳過)

在執行任何顯示操作前，USM 會主動向 Wayland 合成器查詢當前的輸出狀態
(`Enabled: yes/no`)。若系統已處於預期狀態，USM 將直接跳過執行。
這項設計確保了開機時的靜默啟動 (Silent Boot)，並防止重複觸發導致的畫面閃爍。

### C. EDID 防呆機制

系統喚醒時常有假訊號，僅檢查 HDMI 狀態是否為 `connected` 並不可靠。
USM 會驗證 EDID 檔案大小，確保大於 0 位元組時才確認為有效實體連線，
避免盲目對未連接的端子下達設定指令。

### D. 硬體頻寬解套機制 (3 步驟同步)

Raspberry Pi CM4 的 VC4 KMS 驅動在面臨原子提交 (Atomic Commit，例如
同時喚醒直立 DSI 並關閉 2K HDMI 螢幕) 時，常因瞬間的 CMA 記憶體頻寬
耗盡而拒絕套用設定。USM 採用非對稱切換策略來解決此硬體缺陷：

1. **低解析度同步：** 暫時將雙螢幕強制降為低解析度 (720x1280 與 1024x768)
以清空頻寬瓶頸。
2. **恢復解析度：** 將外接螢幕重新拉回預設的高解析度狀態。
3. **收尾定型：** 根據使用者的設定模式，安全地關閉多餘的螢幕輸出。

### E. 自訂執行掛鉤 (Hooks)

USM 允許使用者透過外部腳本執行自訂操作。在完成螢幕切換後，
USM 會檢查 `hook-plug.sh` 或 `hook-unplug.sh` 是否存在。
若具備執行權限，腳本會於背景觸發，確保不阻塞主監聽迴圈。
