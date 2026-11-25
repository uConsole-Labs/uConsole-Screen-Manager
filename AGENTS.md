# Agent Development Rules & Architectural Charter for uConsole-Screen-Manager (USM)

<project_identity>
## 1. Project Overview & Core Philosophy
- **Name**: `uConsole-Screen-Manager` (`usm`)
- **Tagline**: An event-driven Wayland display, hardware power, HDMI audio, and swayidle manager for ClockworkPi uConsole (CM5) running Raspberry Pi OS Trixie (`labwc`).
- **Core Philosophy**:
  1. **Pure Native Stack & Zero-Polling Efficiency**:
     - STRICTLY FORBIDDEN: Introducing external language runtimes (Python, Node.js, Go, Rust) or third-party package managers (`npm`, `pip`, `cargo`).
     - Pure Native Standards: POSIX/Bash scripts (`set -euo pipefail`) interacting directly with Linux DRM sysfs, `udevadm`, `dbus-monitor`, Wayland (`wlr-randr`, targeted `wlopm`), PipeWire (`pw-cli`/`wpctl`), `systemd`, `swayidle`, and `mako`/`notify-send`.
     - Event-Driven Architecture: Daemon monitoring MUST react to kernel/udev and logind D-Bus signals over a FIFO, never via background polling loops.
  2. **Dual-Sided UX Mandate**:
     - **User UX (Zero Burden & Hardware Safety)**: Seamless HDMI plug/unplug switching, safe DSI (`panel-cwu50`) hardware power sequencing, HDMI audio kernel-crash prevention, non-intrusive idle management, and full preservation of user-customized configurations.
     - **Developer UX / DX (Self-Explanatory)**: Maximum readability and lowest cognitive load for developers and AI assistants. All file names, function names, configuration keys, and log messages must be explicit, plain, and immediately understandable at a glance.
</project_identity>

<strict_stack_boundaries>
## 2. Technology Stack & Zero-Dependency Boundaries
- **Runtime**: GNU Bash (`#!/bin/bash`, `set -euo pipefail`) on Raspberry Pi OS Trixie (Wayland / `labwc`).
- **Allowed System Primitives**:
  - Wayland & Display: `wlr-randr`, `wlopm` (strictly targeted to `$SCREEN_OUT_EXT` only; NEVER wildcard `*` and NEVER on `DSI-2`), `swayidle`, Linux DRM/backlight/framebuffer sysfs (`/sys/class/drm`, `/sys/class/backlight`, `/sys/class/graphics/fb0`, `/sys/bus/mipi-dsi/drivers/panel-cwu50`).
  - Events & Services: `udevadm`, `dbus-monitor`, `systemctl --user`, `systemd-run --user`, `journalctl`.
  - Audio & Notifications: `pw-cli`, `wpctl`, `mako`, `notify-send`.
  - Standard GNU coreutils / text utilities (`awk`, `sed`, `grep`, `find`, `mkfifo`, `mktemp`, `pgrep`, `pkill`, `timeout`).
- **Absolute Prohibitions**:
  - FORBIDDEN: Adding Python, Node.js, Perl, Ruby, Go, or Rust runtime dependencies to `src/` or `install.sh`.
  - FORBIDDEN: `package.json`, `requirements.txt`, `node_modules`, or external third-party daemon frameworks.
  - FORBIDDEN: Using `wlopm --off *` / `wlopm --on *` in USM-managed idle scripts, as wildcard output power commands wake `DSI-2` during HDMI `single` mode and bypass `usm_hw_screen_on` sequencing.
</strict_stack_boundaries>

<developer_ux_and_naming_rules>
## 3. Developer UX (DX) & Self-Explanatory Naming Conventions
Every AI Agent contributing to this repository MUST uphold these naming disciplines:
1. **Repository File Map**:
   - `AGENTS.md`: AI development rules and architectural invariants (English-only).
   - `DESIGN.md`: Bilingual (EN / Traditional Chinese) system architecture and design specification.
   - `README.md`: Bilingual (EN / Traditional Chinese) user documentation, CLI reference, and installation guide.
   - `VERSION`: Semantic version string installed to `~/.config/usm/VERSION`.
   - `LICENSE`: Project license.
   - `install.sh`: Standalone installer, labwc/mako/swayidle configurator, and `usm-uninstall` generator.
   - `conf/usm.conf`: Default user configuration template installed to `~/.config/usm/usm.conf`.
   - `src/usm-cli.sh`: Main CLI tool, display/hardware/audio/swayidle controller, and event monitor daemon installed to `~/.local/bin/usm-cli.sh`.
   - `src/hooks/usm_hook_*.sh`: Lifecycle hook templates (`hdmi_plug`, `hdmi_unplug`, `usm_start`, `usm_stop`) installed to `~/.config/usm/hooks/`.
   - `systemd/usm.service`: User systemd unit installed to `~/.config/systemd/user/usm.service`.
2. **Function Naming**:
   - `cmd_*`: CLI command entrypoints dispatched by `main()` (e.g., `cmd_monitor`, `cmd_screen_int`, `cmd_screen_ext`, `cmd_screen_dual`, `cmd_screen_on`, `cmd_screen_off`, `cmd_screen_switch`, `cmd_idle_off`, `cmd_idle_on`, `cmd_start_swayidle`, `cmd_stop_swayidle`, `cmd_hdmi_audio_off`, `cmd_status`, `cmd_hw_status`).
   - `usm_*`: Display, hardware power, and state query helpers (e.g., `usm_hw_screen_on`, `usm_hw_screen_off`, `usm_is_screen_detected`, `usm_is_screen_on`).
   - `handle_event_*`: Daemon event handlers (`handle_event_udev`, `handle_event_suspend`, `handle_event_resume`).
   - `_*`: Private internal helper functions (e.g., `_get_backlight_path`, `_get_fb_path`, `_build_wlr_internal_cmd`).
   - Strictly prohibit ambiguous or cryptic abbreviations.
3. **Configuration & Variable Naming**:
   - All user configuration keys in `conf/usm.conf` MUST use `UPPER_SNAKE_CASE` prefixed with `USM_` (e.g., `USM_MODE`, `USM_HDMI_DISABLE_SWAYIDLE`, `USM_ENABLE_HW_POWER_CONTROL`, `USM_IDLE_SCREENSAVER_TIMEOUT`).
   - Script constants MUST use `readonly` `UPPER_SNAKE_CASE`.
   - Function-scoped variables MUST be declared with `local`.
4. **Line Wrapping & Character Limit Standards**:
   - **`AGENTS.md` Natural Language Wrapping Exception**: `AGENTS.md` adopts natural language wrapping (semantic line breaks per sentence or clause) for fluid reading and contextual coherence.
   - **Strict 80-Character Limit Everywhere Else**: All other files across the repository (including `src/usm-cli.sh`, `install.sh`, `conf/usm.conf`, `DESIGN.md`, `README.md`, and comments) MUST strictly adhere to a maximum of 80 characters per line.
   - **Allowed Exceptions**: Unbreakable URLs and continuous literal strings that cannot be split safely.
5. **English-Only Invariant for `AGENTS.md`**:
   - `AGENTS.md` MUST strictly and exclusively be authored in English to maintain cross-agent comprehension and global developer consistency.
</developer_ux_and_naming_rules>

<architectural_invariants>
## 4. Immutable Architectural Invariants (DO NOT COMPROMISE)
Every AI agent writing or refactoring code for this project MUST strictly uphold these non-negotiable invariants:

1. **Event-Driven Zero-Polling Daemon**:
   - `cmd_monitor()` MUST listen to `udevadm monitor --subsystem=drm` and `dbus-monitor` (`PrepareForSleep`) concurrently through a single FIFO (`$FIFO_PATH`).
   - Periodic background polling loops for HDMI detection are strictly forbidden.
2. **EDID-Verified HDMI Detection & State-Transition Gating**:
   - `check_hdmi_state()` MUST verify both DRM `status == "connected"` AND `edid` size `> 0` to reject false wake-up signals.
   - `handle_event_udev()` MUST ignore DRM `change` events where `current_state == LAST_STATE` rather than dropping subsequent transitions via timestamp cooldowns.
3. **Hardware Power Sequencing & HPD Preservation**:
   - Turning a display ON MUST follow `[usm_hw_screen_on] -> [poll wlr-randr if DSI was DRM-off] -> [exec_wlr_randr]`.
   - Turning a display OFF MUST follow `[exec_wlr_randr] -> [usm_hw_screen_off]`.
   - `usm_hw_screen_off "HDMI"` MUST bypass DRM `status=off` by default (`USM_HDMI_DRM_FORCE_OFF="false"`) to preserve kernel Hot Plug Detect (HPD).
4. **Anti-Blackout & `NOOP` Output Guards**:
   - `exec_wlr_randr()` MUST abort with exit code 1 before disabling any placeholder `NOOP` output if no target `--output` arguments were configured (`(( ${#full_cmd[@]} == 1 ))`) or if external screen was requested ON while missing.
   - `cmd_screen_on()` MUST verify Wayland compositor connectivity (`auto_update_wayland_display` + `wlr-randr >/dev/null 2>&1`) before mutating hardware sysfs, and recover `DSI-2` via `cmd_screen_int` when no active outputs appear after `cmd_screen_off`.
5. **HDMI Audio Kernel-Crash Prevention**:
   - `USM_HDMI_AUDIO_DEFAULT_STATE` defaults to `"off"`, applied asynchronously on daemon startup via PipeWire (`pw-cli` / `wpctl`) to prevent hotplug kernel panics.
6. **Swayidle Managed Block & UPM Power Key Compatibility**:
   - `install.sh` MUST wrap USM-managed `autostart` entries in `# === USM Swayidle Config Start ===` and `# === USM Swayidle Config End ===` markers and preserve original `wlopm` lines with `# [USM backup] ` so `usm-uninstall` can cleanly restore them.
   - `install.sh` and `usm-uninstall` MUST NEVER overwrite, duplicate, or restart custom non-`wlopm` user `swayidle` configurations.
   - `cmd_idle_off()` and `cmd_idle_on()` MUST remain silent by default, coordinate via `"$USM_RUN_DIR/idle_off.lock"` (storing `ext`/`int`/`dual`), use targeted `wlopm` for `$SCREEN_OUT_EXT` DPMS standby and `usm_hw_screen_off "DSI"` (`bl_power=4`) for internal UPM battery powersave, sync `_usm_wake_hdmi_dpms` on hotplug/resume/manual wake, and wake idle-slept screens (including HDMI) when UPM Power Key triggers `cmd_screen_switch()`.
   - `cmd_stop_swayidle()` and `cmd_start_swayidle()` MUST poll up to 1 second (`0.1s` intervals) to confirm process exit/startup and prevent restart race conditions.
7. **Strict Bash Error Safety**:
   - All scripts MUST pass `bash -n` and `shellcheck` with zero errors and zero warnings under `set -euo pipefail`.
   - Exit traps (`cleanup_on_exit`) MUST guard potentially unset variables with `${VAR:-}` and non-zero commands (such as `systemctl is-system-running` on `degraded` hosts) with `|| true`.
</architectural_invariants>

<agent_execution_discipline>
## 5. Agent Behavioral Rules & Operational Governance

### 5.1 Autonomous Execution Boundaries & Modification Consent Gate
1. **Strict Prohibition on Proactive Skill Loading**:
   - The agent is STRICTLY FORBIDDEN from proactively reading, viewing, or loading any `SKILL.md` files under any circumstances unless the user explicitly names and commands that specific skill in their immediate prompt.
2. **Source Code Modification Consent Gate**:
   - Whenever an error, bug, or refactoring requirement is identified that necessitates changing existing repository files, the agent MUST NOT immediately call file modification tools.
   - The agent MUST first report a structured proposal detailing:
     1. Exact symptom and root cause with clickable file and line links.
     2. Side-effect and impact assessment on other modules (including UPM integration when relevant).
     3. Concrete proposed unified diff preview aligned to exact line numbers.
     4. Post-change verification and test plan.
   - The agent MUST halt and await explicit user approval before making any edits.
   - **No Overwriting Existing Files**: When updating an existing file, ALWAYS use targeted edit tools (`edit_file`). Overwriting an existing file wholesale with `write_file` is STRICTLY FORBIDDEN.
3. **No Unsolicited Version Control Mutations**:
   - The agent is STRICTLY FORBIDDEN from running version control mutation commands (`git commit`, `git push`, `git checkout`, `git branch`, `git reset`, etc.) unless the user explicitly commands it in their immediate prompt.
4. **No Speculative Feature Drift**:
   - Never introduce speculative features or unrequested refactors outside the agreed scope.
5. **Mandatory Use of Built-in Tools (Main Agent & All Subagents)**:
   - The main agent AND every invoked subagent MUST strictly prioritize platform built-in tools (`read_file`, `edit_file`, `write_file`, etc.) for all file inspections, readings, creations, and edits.
   - Running shell/bash commands (`cat`, `grep`, `sed`, `awk`, `find`, `wc`) for basic file reading or content manipulation is STRICTLY FORBIDDEN whenever built-in tools can perform the task.
   - Whenever invoking a subagent, the parent prompt MUST explicitly instruct the subagent to use built-in tools only for file reads/edits.
   - `run_command` is reserved strictly for running syntax/lint checks (`bash -n`, `shellcheck`), installer/service commands (`./install.sh`, `systemctl`), or system diagnostics that built-in tools cannot perform.

### 5.2 Verification & Execution Security Invariants
1. **Mandatory Static & Functional Verification**:
   - Every modification to `src/usm-cli.sh` or `install.sh` MUST be verified with `bash -n` and `shellcheck` with zero warnings before reporting completion.
   - Functional changes affecting hardware, hotplug, or `swayidle` MUST include an explicit on-device test checklist covering boot-with-HDMI, hotplug-after-boot, unplug, Power Key (`screen-switch`), and install/uninstall scenarios.
2. **No Inline Script Injection**:
   - Avoid opaque inline eval/script injection commands; keep verification transparent and reproducible.
3. **Repository Permission Invariants**:
   - Maintain clean repository permissions; `install.sh` handles setting executable permissions (`chmod +x`) on deployed binaries (`~/.local/bin/usm-cli.sh`, `~/.local/bin/usm-uninstall`) and hooks.

### 5.3 Release Discipline & Documentation Sync
1. **Root-Cause Fixes Only (Zero Bug Masking)**:
   - NEVER propose configuration workarounds that mask an underlying code bug as a primary fix. Identify and fix the root cause first.
2. **Bilingual Documentation Sync**:
   - Any CLI command, configuration key, or lifecycle change MUST be synchronized across both the English and Traditional Chinese sections of `README.md` and `DESIGN.md`.
3. **Commit Message Standards**:
   - Follow Conventional Commits format:
     - **Title**: Max 50 characters, imperative mood (`type(scope): subject`).
     - **Blank Line**: Exactly one empty line between title and body.
     - **Body**: Bulleted list (`- `), max 70 characters per line.
     - **Test Labels**: Each verified check on its own `Test: ` line.
</agent_execution_discipline>

<user_respect_and_non_intrusive_ux>
## 6. User Respect, Truthful State & Non-Intrusive UX Charter
Every AI agent and contributor must uphold these core UX disciplines:

1. **No Presumed Assumptions (Evidence-Grounded Diagnosis)**:
   - Ground every root-cause claim in exact source lines and runtime logs (`~/.local/state/usm/logs/`). Explicitly separate verified facts from unverified hypotheses.
2. **Non-Intrusive Idle & Installer Feedback**:
   - Automated idle transitions (`cmd_idle_off`, `cmd_idle_on`) MUST remain silent (no `notify_user` spam).
   - `install.sh` and `usm-uninstall` MUST clearly and explicitly log every action taken on `autostart` and `swayidle` (added, migrated, skipped, retained, or restored).
3. **Truthful, Deterministic State**:
   - Never report false success (e.g., returning 0 when `wlr-randr` configured zero outputs, or claiming `swayidle` started/stopped without verifying process state).
</user_respect_and_non_intrusive_ux>
