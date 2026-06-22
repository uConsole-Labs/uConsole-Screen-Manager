# uConsole Screen Manager (USM)

A lightweight, event-driven display manager for ClockworkPi uConsole on Wayland. It automatically switches screens via HDMI plug/unplug with 0% background CPU usage.

[點擊此處跳轉至中文版說明](#中文版說明-traditional-chinese)

**⚠️ Requirements:** Exclusive for Raspberry Pi OS Trixie (Wayland / Labwc).
* Does NOT support older X11-based environments (Buster/Bullseye).

---

## 🚀 Features

* **Zero CPU Polling:** Uses kernel `udevadm` DRM events to trigger display changes instantly instead of wasteful `sleep` loops.
* **Auto Switching:** Automatically turns off the internal display when an HDMI cable is connected, and restores it when disconnected.
* **Fail-Safe Mechanism:** Verifies successful HDMI handshake before disabling the internal screen to prevent black screen lockouts.
* **Dual Display Mode:** Supports both single-screen auto-switch and dual-screen extend modes.
* **Taskbar Alignment:** Automatically reloads `sfwbar` or `waybar` to keep your taskbar on the active primary screen.
* **Clean Installation:** Comes with an automated install script and a self-destructing uninstall command.

## 🛠️ Installation

Clone this repository and run the installer script:

```bash
git clone [https://github.com/TheRetroMars/uConsole-Screen-Manager.git](https://github.com/TheRetroMars/uConsole-Screen-Manager.git)
cd uConsole-Screen-Manager
./install.sh

```

The installer will automatically set up the required background user service (`usm.service`) and copy the default configuration file. You can safely delete the cloned repository after installation.

## ⚙️ Configuration

The configuration file is located at `~/.config/usm/usm.conf`. You can customize the behavior by editing this file:

* `USM_MODE`: Set to `"single"` (default, turns off internal screen) or `"extend"` (keeps both screens on).
* `USM_EXT_RES`: Force a specific external resolution (e.g., `"1920x1080@60"`). Leave empty `""` for automatic detection.
* `USM_EXT_SCALE`: Adjust fractional scaling for high-DPI external monitors (e.g., `"1.5"`).

## 🗑️ Uninstallation

To completely remove USM and its background services, simply run the globally available uninstall command in your terminal:

```bash
usm-uninstall

```

---

# 中文版說明 (Traditional Chinese)

專為 ClockworkPi uConsole 設計的輕量級、事件驅動螢幕管理器。支援 HDMI 插拔自動切換螢幕，且背景 CPU 佔用率為 0%。

**⚠️ 系統需求:** **僅支援最新的 Raspberry Pi OS Trixie (Wayland / Labwc 環境)。**

* 不支援舊版 X11 顯示架構 (Buster/Bullseye)。

---

## 🚀 核心特點

* **零 CPU 消耗監聽：** 捨棄傳統耗效能的迴圈偵測，直接監聽 Linux 核心 DRM 硬體事件，平時背景零佔用。
* **全自動切換：** 插入 HDMI 線自動點亮外接大螢幕並關閉內建小螢幕；拔除線材瞬間自動恢復掌機螢幕。
* **防黑屏機制：** 在關閉內建螢幕前，會嚴格驗證外接螢幕是否成功輸出訊號，徹底避免「兩邊都不亮」的死機窘境。
* **支援雙螢幕：** 可透過設定檔切換為「單螢幕切換」或「雙螢幕延伸」模式。
* **工作列跟隨：** 自動重新載入 `sfwbar` 或 `waybar`，確保你的工作列（Taskbar）永遠出現在你正在使用的主螢幕上。
* **無痕安裝與移除：** 內建一鍵安裝腳本，並提供乾淨俐落的全自動解除安裝指令。

## 🛠️ 安裝教學

在終端機輸入以下指令下載並安裝：

```bash
git clone [https://github.com/TheRetroMars/uConsole-Screen-Manager.git](https://github.com/TheRetroMars/uConsole-Screen-Manager.git)
cd uConsole-Screen-Manager
./install.sh

```

安裝程式會自動幫你配置好所有背景服務與設定檔目錄。安裝完成後，你可以直接刪除剛剛下載的 Git 資料夾。

## ⚙️ 設定檔說明

設定檔位於 `~/.config/usm/usm.conf`。你可以自由編輯此檔案來改變輸出邏輯：

* `USM_MODE`：可設定為 `"single"`（預設，單螢幕切換）或 `"extend"`（雙螢幕延伸模式）。
* `USM_EXT_RES`：強制指定外接螢幕解析度（例如 `"1920x1080@60"`）。若留空 `""` 則由系統自動偵測。
* `USM_EXT_SCALE`：設定外接螢幕的畫面縮放比例，適合 4K 螢幕使用（例如 `"1.5"`）。

## 🗑️ 移除教學

如果未來不再需要使用此工具，只需在終端機輸入以下指令，系統便會自動停止服務並清除所有相關檔案：

```bash
usm-uninstall

```
