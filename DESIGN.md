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

USM uses a strictly one-way, event-driven data flow.

```text
+---------------+      +-------------------+      +-----------------+
| Linux Kernel  |Event | udevadm (Monitor) |Wakes | usm-core.sh     |
| (DRM Subsys)  |----->| (Waits passively) |----->| (Logic Handler) |
+---------------+      +-------------------+      +-----------------+
                                                           |
                                                           | 1. Validate HW
                                                           v
                                                +--------------------+
                                                | /sys/class/drm/    |
                                                | HDMI status & EDID |
                                                +--------------------+
                                                           |
                                                           | 2. Apply Output
                                                           v
                                                +--------------------+
                                                | Wayland Compositor |
                                                | (wlr-randr)        |
                                                +--------------------+
                                                           |
                                                           | 3. Set Primary
                                                           v
                                                +--------------------+
                                                | wf-panel-pi        |
                                                | (Taskbar Reload)   |
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

### B. The EDID Fail-Safe Mechanism

Checking if the HDMI port status is `connected` is insufficient due to false
positives during system wake-up. USM verifies the size of the EDID file
(`/sys/class/drm/card*-HDMI-A-1/edid`). If the size is greater than 0, USM
confirms a valid physical connection. Furthermore, USM will only disable the
internal display after verifying that `wlr-randr` has successfully registered
the external output.

### C. Display Modes and Positioning

* **Single Mode:** Automatically turns off the internal display when HDMI
is connected.
* **Dual Mode:** Keeps both displays active. Users can define the layout
position (e.g., `right`) and scaling fractional values via the
configuration file.

### D. Primary Display Alignment

Wayland's `wlr-randr` lacks a `--primary` parameter. USM manages the primary
display by restarting the native taskbar (`wf-panel-pi`) after the display
configuration is applied, ensuring the user interface correctly anchors to
the designated primary screen.

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

USM 採用嚴格的單向、事件驅動資料流。

```text
+---------------+      +-------------------+       +--------------+
| Linux 核心     | 事件 | udevadm (監聽器)    | 喚醒  | usm-core.sh  |
| (DRM 子系統)   |----->| (被動等待 0% CPU)   |----->| (主控邏輯腳本)  |
+---------------+      +-------------------+       +--------------+
                                                           |
                                                           | 1. 驗證實體硬體
                                                           v
                                                +--------------------+
                                                | /sys/class/drm/    |
                                                | HDMI 狀態與 EDID 檔  |
                                                +--------------------+
                                                           |
                                                           | 2. 切換顯示輸出
                                                           v
                                                +--------------------+
                                                | Wayland 合成器      |
                                                | (wlr-randr)        |
                                                +--------------------+
                                                           |
                                                           | 3. 設定主螢幕
                                                           v
                                                +--------------------+
                                                | wf-panel-pi        |
                                                | (重啟官方工作列)      |
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

### B. EDID 防呆機制

系統喚醒時常有假訊號，僅檢查 HDMI 狀態是否為 `connected` 並不可靠。
USM 會驗證 EDID 檔案大小，大於 0 時才確認為有效實體連線。此外，
USM 會先確認 `wlr-randr` 成功註冊外接輸出後，才會關閉內建螢幕。

### C. 顯示模式與相對位置

* **單螢幕 (Single) 模式：** 偵測到 HDMI 插入時，自動關閉內建螢幕。
* **雙螢幕 (Dual) 模式：** 兩組螢幕皆保持輸出。使用者可透過設定檔
指定外接螢幕的相對位置（如右側 `right`）與畫面縮放比例 (Scale)。

### D. 主螢幕介面對齊

Wayland 的 `wlr-randr` 不具備 `--primary` 參數。USM 透過在顯示狀態
套用完成後，重新啟動官方工作列 (`wf-panel-pi`)，以確保使用者介面
正確綁定至設定的主螢幕上。

### E. 自訂執行掛鉤 (Hooks)

USM 允許使用者透過外部腳本執行自訂操作。在完成螢幕切換後，
USM 會檢查 `hook-plug.sh` 或 `hook-unplug.sh` 是否存在。
若具備執行權限，腳本會於背景觸發，確保不阻塞主監聽迴圈。
