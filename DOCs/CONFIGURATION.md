# WorkspaceManager: Configuration Schema & Syntax Rules

**WorkspaceManager** is configured entirely via a single `workspaces.json` file. There is no built-in GUI editor for configurations; the tool assumes users are comfortable editing JSON. 

To ensure the orchestration engine parses your environment flawlessly and safely, your JSON file must adhere to the following strict syntax rules.

## The JSON Blueprint

```json
{
  "comment": "Top-level note: this file configures workstation modes.",
  "description": "WorkspaceManager profiles for this machine.",
  "_config": {
    "shortcut_prefix_start": "!Start-",
    "shortcut_prefix_stop": "!Stop-"
  },
  "Audio_Production": {
    "comment": "Live tracking and low-latency profile.",
    "description": "Primary DAW workspace for recording sessions.",
    "type": "stateful",
    "tags": ["Audio", "Live"],
    "power_plan": "High performance",
    "pnp_devices_enable": ["*USB Audio*"],
    "pnp_devices_disable": ["*Bluetooth*"],
    "registry_toggles": [
      { "path": "HKLM:\\SOFTWARE\\Contoso\\Audio", "name": "LowLatency", "value_start": 1, "value_stop": 0, "type": "DWord" }
    ],
    "services": [
      "eLicenserSvc",
      "t 3000",
      "Audiosrv"
    ],
    "executables": [
      "'C:/Program Files/Steinberg/Cubase 12/Cubase12.exe' --profile Live",
      "C:\\Tools\\AudioMixer.exe",
      "'./CustomScripts/Set_Displays_60Hz.lnk'"
    ],
    "scripts_start": [
      "'C:/Program Files/My Scripts/start.ps1' -Verb",
      "'./CustomScripts/local-start.ps1'"
    ],
    "scripts_stop": [
      "C:/Program Files/My Scripts/stop.bat",
      "'./CustomScripts/local-stop.bat'"
    ],
    "protected_processes": [
      "Cubase12",
      "AudioMixer"
    ],
    "reverse_relations": [
      "wuauserv"
    ],
    "firewall_groups": [
      "File and Printer Sharing",
      "Core Networking"
    ]
  }
}
```

## Syntax Rules & Constraints

### 1. The Execution String (Paths & Arguments)
Windows file paths often contain spaces, and many applications require command-line arguments. To pass these safely through JSON into the orchestration engine, follow this rule:
* **No Arguments & No Spaces:** Just provide the path. 
  `"C:/Tools/App.exe"`
* **Spaces in Path or Adding Arguments:** You **MUST** wrap the executable path in single quotes (`'`), followed by a space, followed by your arguments. The engine will safely split these before execution.
  *Correct:* `"'C:/Program Files/My App/app.exe' --fullscreen -v"`
* **Relative paths (quoted only):** For `executables`, `scripts_start`, and `scripts_stop`, you may use a path relative to the folder that contains `workspaces.json` and the WorkspaceManager `.ps1` scripts (`Orchestrator.ps1`, `WorkspaceState.ps1`, `Dashboard.ps1`). The path **MUST** be wrapped in single quotes and **MUST** start with `./` or `.\` immediately after the opening quote (before any other character).
  *Correct:* `"'./CustomScripts/Set_Displays_60Hz.lnk'"` or `"'.\CustomScripts\Set_Displays_60Hz.lnk'"` (in JSON, double each backslash in the string value, e.g. `"'.\\CustomScripts\\Set_Displays_60Hz.lnk'"`).
  The engine resolves that segment to an absolute path using `$PSScriptRoot` and `Join-Path` (normalizing `/` in the relative segment to platform directory separators) before `Test-Path`, `Start-Process`, or process lookup, so elevated helpers (for example `gsudo`) do not run with a working directory that breaks relative paths.
  *Note:* A quoted path that begins with `'?./` / `'?.\` is not expanded; use an absolute path for optional items, or a non-relative form the engine already supports.

### 2. The Slash Rule (`\\` or `/`)
If you copy and paste a file path directly from Windows Explorer, it will contain single backslashes (e.g., `C:\Program Files`). **This will crash the JSON parser.** JSON treats a single backslash as an escape character.
* You must either manually double every backslash: `"C:\\Program Files\\App.exe"`
* Or replace them with forward slashes: `"C:/Program Files/App.exe"`

### 3. Timers (`t [ms]`)
To prevent race conditions (e.g., an application crashing because its required background service hasn't fully spun up yet), you can inject delays directly into the `services` or `executables` arrays. 
* The syntax is strictly the lowercase letter `t`, a single space, and the duration in milliseconds.
* *Example:* `"t 5000"` will halt the pipeline execution for exactly 5 seconds before proceeding to the next item in the array.

### 4. Custom Synchronous Scripts (`scripts_start` / `scripts_stop`)
Use these arrays to run custom synchronous scripts during orchestration.

* **Syntax:** `scripts_start` and `scripts_stop` use the exact same *Execution String* rules as `executables` (including **relative quoted paths** that start with `'./` or `'.\`; see §1).
  * No arguments and no spaces: just provide the path. `"C:/Tools/MyScript.bat"`
  * Spaces in the path and/or arguments: wrap the script path in single quotes (`'`), then add a space and the arguments.
    * Correct example: `"'C:/My Script.ps1' -arg1 -v"`
* **Synchronous execution:** the engine pauses (`-Wait`) and waits for each script to finish before moving to the next item.
* **Shortcuts (`.lnk` / `.url`):** These are started with **`System.Diagnostics.ProcessStartInfo`** (`UseShellExecute = true`) and **`WorkingDirectory`** set to the shortcut’s folder. **`Start-Process -FilePath`** treats **`()`** as wildcards, which breaks names like `Make Monitors 60hz (Performance).lnk` with “Windows cannot find the path specified.” ShellExecute is used so the shortcut is not tied to the orchestrator console the way `-NoNewWindow` batch launches are.
* **Timers:** you may include timer tokens like `t 3000` in `scripts_start` (it delays like `executables`). If included in `scripts_stop`, timer tokens are ignored/skipped.

### 5. Protected Processes (No Extensions)
The `protected_processes` array acts as a safety net to prevent data loss. If the engine attempts to stop a Workspace and detects one of these processes in RAM, it will halt and ask for user confirmation.
* Enter the raw process name exactly as it appears in Task Manager's "Details" tab.
* **Do NOT include the `.exe` extension.** (Note: The engine will auto-strip `.exe` if accidentally included, but standard practice is to omit it).
* *Correct:* `"WINWORD"` | *Incorrect:* `"WINWORD.exe"`

### 6. True Service Names
When listing background services, you must use the internal **Service Name**, not the "Display Name" shown in the Windows GUI. 
* To find the true name, open `services.msc`, right-click a service -> Properties, and look at the "Service name:" field at the top.
* *Correct:* `"wuauserv"` | *Incorrect:* `"Windows Update"`

### 7. Firewall Groups
The `firewall_groups` array controls Windows Firewall rule groups by exact Display Group name. During Start, the engine enables each group; during Stop, it disables each group.
* Use exact Display Group strings as shown in Windows Defender Firewall with Advanced Security.
* Commands used by the engine:
  * `Enable-NetFirewallRule -DisplayGroup "Name"`
  * `Disable-NetFirewallRule -DisplayGroup "Name"`
* *Example:* `"firewall_groups": ["File and Printer Sharing", "Core Networking"]`

### 8. Global Shortcut Prefixes (`_config`)
You can customize Start Menu shortcut prefixes globally through `_config`.

* `shortcut_prefix_start` controls the prefix used for Start shortcuts.
  * Default: `!Start-`
* `shortcut_prefix_stop` controls the prefix used for Stop shortcuts.
  * Default: `!Stop-`
* Example:
  * `"shortcut_prefix_start": "[BOOT]-"`
  * `"shortcut_prefix_stop": "[HALT]-"`

### 9. Optional Modifier (`?`) For Services And Executables
Prefix a service or executable with `?` to mark it optional.

* Services:
  * `"?warp-svc"`
* Executables:
  * `"?C:/Tools/App.exe"`
  * `"'?C:/Tools/App.exe' -arg"`
* Behavior:
  * If an optional item is missing on the host machine, the engine silently skips it.
  * No prompt and no terminating error are raised for missing optional items.

### 10. Ignored Operator (`#`) For Actionable Arrays
Prefix any actionable string-array item with `#` to fully ignore it at runtime.

* Applies to actionable arrays used by state/orchestration/editor workflows:
  * `services`, `executables`, `scripts_start`, `scripts_stop`, `pnp_devices_enable`, `pnp_devices_disable`, `reverse_relations`, `protected_processes`
* Ignored items are skipped by the engine:
  * no command is executed for that item
  * state math does not count that item
* Dashboard behavior:
  * ignored entries can be toggled on/off from the editor view
  * details view can hide/show ignored entries with `F2`

Example:
* Before: `"pnp_devices_disable": ["*Camera*"]`
* Ignored: `"pnp_devices_disable": ["#*Camera*"]`

### 11. Workspace Type (`type`)
Each workspace may define an optional `type` value.

* Valid values:
  * `"stateful"` (default)
  * `"oneshot"`
* `stateful` workspaces use normal runtime state math (`Ready` / `Stopped` / `Mixed`).
* `oneshot` workspaces are stateless triggers. They do not measure running state and are treated as `Idle` until explicitly run.
  * In Dashboard, oneshot entries are shown as triggerable tasks.
  * In commit flow, oneshot `Run` maps to Orchestrator `Start` only.

**Dashboard TUI (main list):**

* **[Space]** toggles the *desired* outcome for commit. For stateful workspaces, desired maps to Orchestrator **Start** when `Ready` and **Stop** when `Stopped`.
* When **current** state is **Mixed**, [Space] only flips the desired target between `Ready` and `Stopped` (push toward full up or full down). The first press from `Mixed` / `Mixed` sets desired to `Ready`.
* **[Backspace]** clears a pending desired change: desired is reset to **current** for stateful workspaces, or to `Idle` for oneshot (clears a queued **Run**). Those rows then contribute no delta on **Commit**.

### 11b. Workspace description (`description`)
Each workspace object may include an optional `description` string.

* **Type:** string (free text).
* **Purpose:** hints or context about the profile. The Dashboard shows this line under the main table when that workspace row is highlighted (cyan, prefixed with the information symbol ⓘ).
* **Orchestration:** metadata only; Start, Stop, and state logic ignore this key.

### 11c. Post-commit Dashboard messages (`post_change_message`, `post_start_message`, `post_stop_message`)
Each workspace object may include optional strings that the **Dashboard** shows only **after** a successful **Commit** (Enter), when that workspace row actually triggered an orchestration action—the same cases as the commit engine (stateful transitions to `Ready` / `Stopped`, excluding pending `Mixed` targets that do not call the orchestrator; oneshot when **Run** is committed).

The Orchestrator and workspace state logic **ignore** these keys; they are post-execution UI hooks only.

| Key | Type | When shown (after commit) |
|-----|------|---------------------------|
| `post_change_message` | String | The workspace had an orchestration-eligible commit for that row (state altered in the commit sense). |
| `post_start_message` | String | The committed action for that row was **Start** (stateful desired `Ready`, or oneshot `Run`). |
| `post_stop_message` | String | The committed action for that row was **Stop** (stateful desired `Stopped`). |

If any of these produce at least one line for the commit, the Dashboard prints a **REQUIRED ACTIONS** block and waits for a keypress before exiting instead of using the short auto-exit delay.

### 12. Workspace Tags (`tags`)
Each workspace may define an optional `tags` array for Dashboard categorization tabs.

* Example:
  * `"tags": ["Live", "Audio"]`
* Tags are used for tab filtering in the Dashboard UI (for example: `All`, `Live`, `Audio`).

### 13. Hardware, Power, and Registry Desired State
These keys let a workspace enforce host-level desired state.

* `pnp_devices_enable`: array of FriendlyName patterns (wildcards supported). Matching devices must be enabled.
  * Example: `"pnp_devices_enable": ["*USB Audio*"]`
* `pnp_devices_disable`: array of FriendlyName patterns (wildcards supported). Matching devices must be disabled.
  * Example: `"pnp_devices_disable": ["*Bluetooth*"]`
* `power_plan`: exact friendly name of the power plan that must be active.
  * Example: `"power_plan": "High performance"`
* `registry_toggles`: array of objects in this format:
  * `path` (string): registry path (for example `HKLM:\\...`).
  * `name` (string): value name.
  * `value_start` (required): value applied when the workspace is **Started**.
  * `value_stop` (optional): value applied when the workspace is **Stopped** during Phase 4 teardown. If `value_stop` is omitted (or JSON `null`), the Orchestrator does **not** change that registry value on Stop (intentional default for safety).
  * `type` (string): property type passed to `New-ItemProperty` (for example `DWord`).
  * Example: `{"path":"HKLM:\\...","name":"KeyName","value_start":1,"value_stop":0,"type":"DWord"}`

Stop behavior note:
* `power_plan` is not automatically reverted on Stop; use a dedicated Recovery workspace if you need a different plan after stopping.
* Registry toggles are reverted **only** when `value_stop` is set; otherwise the key is left unchanged on Stop.

### 14. Metadata Keys (`comment` and `description`)
To support human-readable notes inside strict JSON, metadata keys are allowed.

* `comment`: free-text note used as inline JSON comment replacement.
* **Top-level `description`:** optional file-level note on the root object (for example, what this `workspaces.json` is for). It is not a workspace profile and is ignored as a profile name by the Dashboard list.
* **Per-workspace `description`:** optional string on each workspace object; see **§11b**. The Dashboard displays it when that profile is highlighted.
* `comment` may appear at top-level and inside workspace objects.
* For runtime behavior, these keys are metadata-only and do not change Start/Stop/state logic (except Dashboard UI for per-workspace `description` as noted above).
