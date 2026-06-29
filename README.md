# uConsole Screen Manager (USM)

A lightweight, event-driven display manager for ClockworkPi uConsole on
Wayland.

[點擊此處跳轉至中文版說明](#中文版說明-traditional-chinese)

## 🛠️ Installation

Clone this repository and run the installer script:

```bash
git clone [https://github.com/TheRetroMars/uConsole-Screen-Manager.git](https://github.com/TheRetroMars/uConsole-Screen-Manager.git)
cd uConsole-Screen-Manager
./install.sh

```

The installer will set up the background service (`usm.service`) and copy
the default config. You can safely delete the cloned repo after installation.

## ⚠️ Requirements

* **OS:** Raspberry Pi OS Trixie (Wayland / Labwc) exclusively.
* **Hardware:** Tested ONLY on Raspberry Pi 5 (CM5/uConsole).
* Does NOT support older X11-based environments (Buster/Bullseye).

## 🚀 Features

* **Zero CPU Polling:** Uses kernel DRM events for instant switching.
* **Idempotent State:** Silent boots and no screen flickering on redundancy.
* **Hardware Workaround:** Dual-track strategy mitigates VC4 bandwidth bugs.
* **EDID Fail-Safe:** Verifies physical handshake before disabling screens.

## 💻 Commands

USM comes with a powerful CLI tool for manual testing and control.
Type `usm` in your terminal to see all available commands:

* `usm monitor`     : Start the DRM event monitor daemon.
* `usm screen-ext`  : Switch output to external display only.
* `usm screen-int`  : Switch output to internal display only.
* `usm screen-dual` : Switch output to both displays.
* `usm start/stop`  : Control the USM background service.
* `usm restart`     : Restart the USM background service.
* `usm notify-test` : Test desktop notifications (requires mako).
* `usm version`     : Print version information.
* `usm read-conf`   : Print the current usm.conf.

## ⚙️ Configuration

The config file is located at `~/.config/usm/usm.conf`:

* `USM_MODE`: `"single"` (turns off internal) or `"dual"` (keeps both on).
* `USM_EXT_RES`: Force external resolution (e.g., `"1920x1080@60"`).
* `USM_EXT_SCALE`: Fractional scaling for external monitors (e.g., `"1.5"`).
* `USM_EXT_POS`: X,Y coordinates for dual mode (e.g., `"1920,0"`).
* `USM_ENABLE_HOOKS`: Set `"true"` to run custom plug/unplug shell scripts.

## 🐛 Debugging & Troubleshooting

If USM is not behaving as expected, you can use the following commands to
troubleshoot the issue.

**1. Check Service Status**
Verify if the background service is actively running without errors:

```bash
systemctl --user status usm.service

```

**2. View Real-time Logs**
Monitor the systemd journal logs to see hardware events and executions:

```bash
journalctl --user -u usm.service -f

```

**3. Manual Monitor Testing**
To see raw DRM events and isolate hardware issues, stop the background
service and run the monitor manually:

```bash
usm stop
usm monitor

```

Plug and unplug your HDMI cable to see the real-time EDID validation.
Press `Ctrl+C` to exit the monitor mode, then restart the service:

```bash
usm start

```

## 🚨 Emergency Troubleshooting (Black Screen Recovery)

If a severe Wayland crash occurs and both the internal and external screens
become completely black or unresponsive, follow these steps to recover your
uConsole safely:

1. **Unplug the HDMI cable** physically from the uConsole.
2. Press **`Fn + Ctrl + Alt + F2`** simultaneously on your keyboard to force a
   switch to the underlying TTY hardware terminal.
3. **Log in:** Type your username and press Enter, then type your password
   (characters will not appear on screen) and press Enter.
4. **Reboot:** Type **`sudo reboot`** and press Enter. (If the system is totally
   frozen, use `sudo reboot -f` to force it).

The uConsole will restart and safely boot back onto the internal DSI screen.

## 🗑️ Uninstallation

To completely remove USM, run the following command and confirm with 'y':

```bash
usm-uninstall

```

---

# 中文版說明 (Traditional Chinese)

專為 ClockworkPi uConsole 設計的輕量級、事件驅動螢幕管理器。

## 🛠️ 安裝教學

在終端機輸入以下指令下載並安裝：

```bash
git clone [https://github.com/TheRetroMars/uConsole-Screen-Manager.git](https://github.com/TheRetroMars/uConsole-Screen-Manager.git)
cd uConsole-Screen-Manager
./install.sh

```

安裝程式會自動配置背景服務與設定檔。安裝完成後，即可刪除下載的資料夾。

## ⚠️ 系統需求

* **作業系統:** 僅支援 Raspberry Pi OS Trixie (Wayland / Labwc)。
* **硬體限制:** 目前 **僅在 Raspberry Pi 5 (CM5/uConsole) 上測試過**。
* 不支援舊版 X11 顯示架構 (Buster/Bullseye)。

## 🚀 核心特點

* **零 CPU 消耗：** 直接監聽 Linux DRM 事件，平時背景零佔用。
* **冪等性防護：** 開機靜默啟動，避免重複觸發導致的畫面閃爍。
* **硬體頻寬解套：** 循序切換與同步雙軌策略，具備自動黑屏救援機制，避開頻寬問題。
* **EDID 防呆：** 嚴格驗證實體連線，徹底避免「兩邊都不亮」的死機窘境。

## 💻 終端機指令 (Commands)

USM 提供完整的手動控制與測試指令。在終端機輸入 `usm` 即可使用：

* `usm monitor`     : 啟動 DRM 事件監聽守護行程 (Daemon)。
* `usm screen-ext`  : 強制切換至「僅外接螢幕」輸出。
* `usm screen-int`  : 強制切換至「僅內建螢幕」輸出。
* `usm screen-dual` : 強制切換至「雙螢幕」同時輸出。
* `usm start/stop`  : 啟動或停止 USM 背景服務。
* `usm restart`     : 重新啟動 USM 背景服務。
* `usm notify-test` : 測試桌面通知功能 (需安裝 mako)。
* `usm version`     : 顯示當前版本號碼。
* `usm read-conf`   : 印出目前的設定檔內容。

## ⚙️ 設定檔說明

設定檔位於 `~/.config/usm/usm.conf`，你可以自由編輯此檔案：

* `USM_MODE`：`"single"` (預設，單螢幕切換) 或 `"dual"` (雙螢幕模式)。
* `USM_EXT_RES`：指定外接螢幕解析度 (如 `"1920x1080@60"`)，留空為自動。
* `USM_EXT_SCALE`：設定外接螢幕的畫面縮放比例 (如 `"1.5"`)。
* `USM_EXT_POS`：雙螢幕模式下的外接螢幕 X,Y 座標 (如 `"1920,0"`)。
* `USM_ENABLE_HOOKS`：設為 `"true"` 可在切換時觸發自訂 Shell 腳本。

## 🐛 除錯與故障排除 (Debugging)

如果 USM 沒有按照預期運作，你可以使用以下指令來檢查系統狀態並進行除錯。

**1. 檢查服務狀態**
確認背景服務是否正在正常執行，且沒有發生崩潰：

```bash
systemctl --user status usm.service

```

**2. 查看即時日誌 (Logs)**
透過 systemd journal 查看硬體事件觸發與腳本執行的詳細日誌：

```bash
journalctl --user -u usm.service -f

```

**3. 手動監聽測試**
如果你想觀察最底層的 DRM 硬體事件與 EDID 狀態，可以先停止背景服務，並手動
執行監聽器：

```bash
usm stop
usm monitor

```

此時你可以嘗試插拔 HDMI 線，畫面上會印出每一次的實體連線與解析度狀態。
測試完畢後，按下 `Ctrl+C` 離開，並記得將服務重新啟動：

```bash
usm start

```

## 🚨 緊急故障排除 (黑屏救援指南)

若 Wayland 合成器發生嚴重崩潰，導致外接與內建螢幕同時黑屏或完全失去回應，
請按照以下步驟安全救援你的 uConsole：

1. **拔除 HDMI 線：** 先從實體上切斷外接螢幕的連接。
2. **進入純文字終端機：** 同時按住鍵盤上的 **`Fn + Ctrl + Alt + F2`**，強制
   切換至底層的 TTY 終端機介面。
3. **登入系統：** 依照畫面提示輸入你的使用者帳號並按下 Enter，接著盲打輸入
   你的密碼（畫面不會顯示字元）並按下 Enter 完成登入。
4. **強制重啟：** 輸入 **`sudo reboot`** 並按下 Enter（若系統完全卡死，可改用
   `sudo reboot -f` 強制執行）。

系統重新啟動後，畫面就會安全恢復至內建的 DSI 掌機螢幕上。

## 🗑️ 移除教學

若需解除安裝，只需在終端機輸入以下指令並輸入 'y' 確認：

```bash
usm-uninstall

```
