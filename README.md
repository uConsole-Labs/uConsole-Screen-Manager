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
* `usm screen-on`   : Turn on screens based on detected hardware and mode.
* `usm screen-off`  : Turn off all screens.
* `usm screen-switch`: Toggle active screen(s) off/on (UPM Power Key).
* `usm idle-off`    : Silently sleep active screen(s) on idle (for swayidle).
* `usm idle-on`     : Silently wake screen(s) if slept by `idle-off`.
* `usm start/stop`  : Control the USM background service.
* `usm restart`     : Restart the USM background service.
* `usm notify-test` : Test desktop notifications (requires mako).
* `usm hdmi-audio-on` : Enable HDMI audio devices.
* `usm hdmi-audio-off`: Disable HDMI audio devices (prevents kernel crash).
* `usm swayidle-enable` : Start swayidle from `usm.conf` (or custom autostart).
* `usm swayidle-disable` : Stop swayidle and confirm process exit.
* `usm log-enable`    : Enable file logging.
* `usm log-disable`   : Disable file logging.
* `usm hdmi-audio-state`: Print current state of HDMI audio devices.
* `usm hw_status`     : Print detailed hardware and driver status.
* `usm version`     : Print version information.
* `usm read-conf`   : Print the current usm.conf.

## ⚙️ Configuration

The config file is located at `~/.config/usm/usm.conf`:

* `USM_MODE`: `"single"` (external only) or `"dual"` (both displays on).
* `USM_EXT_RES`: Force external resolution (e.g., `"1920x1080@60"`), or `""`
  for automatic preferred mode.
* `USM_IDLE_SCREEN_OFF_TIMEOUT`: Stage 2 idle timeout in seconds before
  turning off screens (default: `"600"`, `"0"` disables).
* `USM_HDMI_IDLE_MODE`: Idle policy while HDMI is connected (only affects
  USM-managed `swayidle`):
  * `"no-screen-off"` (default): Keep Stage 1 screensaver, omit Stage 2
    screen-off (recommended; some monitors drop HPD during DPMS).
  * `"disable"`: Stop `swayidle` completely while HDMI is connected.
  * `"enable"`: Allow normal Stage 2 screen-off even while HDMI is connected.
* `USM_IDLE_SCREENSAVER_TIMEOUT` / `USM_IDLE_SCREENSAVER_CMD`: Optional
  Stage 1 screensaver timeout (seconds, `"0"` disables) and command.
* `USM_IDLE_SCREENSAVER_STOP_CMD`: Optional command to stop Stage 1
  screensaver before Stage 2 screen-off (empty disables; non-blocking).
* `USM_HDMI_AUDIO_DEFAULT_STATE`: `"off"` (default, prevents CM5 hotplug
  kernel crash), `"on"`, or `""` (leave unchanged).
* `USM_HOOKS_ENABLE`: Set `"true"` to run custom plug/unplug shell scripts.
* `USM_LOG_ENABLE`: Set `"true"` to write logs to `~/.local/state/usm/logs/`.

Note: USM automatically stops the default `/usr/bin/kanshi` process on daemon
startup (without modifying `/etc/xdg/labwc/autostart` or
`~/.config/kanshi/config`), preserves custom non-`wlopm` `swayidle` configs,
and restores backups on `usm-uninstall`.


## 🪝 Custom Hooks
USM supports executing custom user scripts at specific lifecycle events.
When `USM_HOOKS_ENABLE="true"` is set in `~/.config/usm/usm.conf`, the
following scripts in `~/.config/usm/hooks/` will be executed if they exist:
*   `usm_hook_hdmi_plug.sh`: Triggered when an HDMI connection is detected.
*   `usm_hook_hdmi_unplug.sh`: Triggered when HDMI is disconnected.
*   `usm_hook_usm_start.sh`: Triggered when the USM background service starts.
*   `usm_hook_usm_stop.sh`: Triggered when the USM background service stops or
    terminates.

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
* `usm screen-on`   : 根據偵測到的硬體與設定模式開啟螢幕。
* `usm screen-off`  : 關閉所有螢幕。
* `usm screen-switch`: 切換作用中螢幕開關（供 UPM 電源鍵使用）。
* `usm idle-off`    : 閒置時靜默休眠作用中螢幕（供 swayidle 使用）。
* `usm idle-on`     : 僅在由 `idle-off` 休眠時靜默喚醒螢幕。
* `usm start/stop`  : 啟動或停止 USM 背景服務。
* `usm restart`     : 重新啟動 USM 背景服務。
* `usm notify-test` : 測試桌面通知功能 (需安裝 mako)。
* `usm hdmi-audio-on` : 開啟 HDMI 音效輸出。
* `usm hdmi-audio-off`: 關閉 HDMI 音效輸出 (能預防拔插當機 Bug)。
* `usm swayidle-enable` : 依 `usm.conf`（或自訂 autostart）啟動 swayidle。
* `usm swayidle-disable`: 終止 swayidle 並確認進程已退出。
* `usm log-enable`    : 啟用日誌寫入功能。
* `usm log-disable`   : 停用日誌寫入功能。
* `usm hdmi-audio-state`: 顯示目前的 HDMI 音效狀態。
* `usm hw_status`     : 印出詳細的硬體與驅動程式狀態。
* `usm version`     : 顯示當前版本號碼。
* `usm read-conf`   : 印出目前的設定檔內容。

## ⚙️ 設定檔說明

設定檔位於 `~/.config/usm/usm.conf`，你可以自由編輯此檔案：

* `USM_MODE`：`"single"`（預設，只開外接）或 `"dual"`（雙螢幕同時亮）。
* `USM_EXT_RES`：指定外接螢幕解析度（如 `"1920x1080@60"`），留空為自動最佳。
* `USM_IDLE_SCREEN_OFF_TIMEOUT`：階段 2 閒置關螢幕逾時（秒，預設 `"600"`，
  `"0"` 為停用）。
* `USM_HDMI_IDLE_MODE`：連接 HDMI 期間的閒置策略（僅影響 USM 管理的
  `swayidle`）：
  * `"no-screen-off"`（預設）：保留階段 1 螢幕保護，略過階段 2 關螢幕
    （建議預設，避免部分螢幕進入 DPMS 後斷 HPD）。
  * `"disable"`：連接 HDMI 期間完全停用 `swayidle`。
  * `"enable"`：連接 HDMI 期間照常執行階段 2 關螢幕。
* `USM_IDLE_SCREENSAVER_TIMEOUT` / `USM_IDLE_SCREENSAVER_CMD`：選用階段 1
  螢幕保護程式逾時（秒，`"0"` 為停用）與自訂指令。
* `USM_IDLE_SCREENSAVER_STOP_CMD`：選用指令，於階段 2 熄屏前先結束階段 1
  螢幕保護程式（留空為停用，失敗不阻斷熄屏）。
* `USM_HDMI_AUDIO_DEFAULT_STATE`：`"off"`（預設，預防 CM5 熱插拔當機）、
  `"on"` 或 `""`（不更動）。
* `USM_HOOKS_ENABLE`：設為 `"true"` 可在切換時觸發自訂 Shell 腳本。
* `USM_LOG_ENABLE`：設為 `"true"` 可將日誌寫入 `~/.local/state/usm/logs/`。

備註：USM 啟動時會自動停用系統預設的 `/usr/bin/kanshi`（不更動
`/etc/xdg/labwc/autostart` 與 `~/.config/kanshi/config`），並完整保留非
`wlopm` 的自訂 `swayidle` 設定，於 `usm-uninstall` 時自動還原備份。


## 🪝 自定義腳本 (Custom Hooks)
USM 支援在特定生命週期事件觸發時執行使用者自定義腳本。
當 `~/.config/usm/usm.conf` 中啟用 `USM_HOOKS_ENABLE="true"` 時，若
`~/.config/usm/hooks/` 目錄下存在以下腳本，USM 將在背景自動執行它們：
*   `usm_hook_hdmi_plug.sh`：偵測到 HDMI 連線時觸發。
*   `usm_hook_hdmi_unplug.sh`：HDMI 斷線時觸發。
*   `usm_hook_usm_start.sh`：USM 背景服務啟動時觸發。
*   `usm_hook_usm_stop.sh`：USM 背景服務停止或終止時觸發。

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
