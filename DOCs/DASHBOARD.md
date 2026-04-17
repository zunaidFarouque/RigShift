## WorkspaceManager Dashboard (`Dashboard.ps1`)

The WorkspaceManager dashboard is an interactive PowerShell TUI for inspecting and changing your machine state declaratively.

Run it from the repository root:

```powershell
pwsh -File .\Dashboard.ps1
```

### App Workloads Tab (Tab 1)

Tab 1 shows **App Workloads** – grouped profiles that manage services and executables for specific tasks (DAW, Office, tools, etc.).

- **Data model**
  - Workloads are defined in `workspaces.json` under:
    - `App_Workloads.<Domain>.<WorkloadName>`
  - Each workload can include:
    - `description`: short human-readable summary.
    - `services`: Windows service names to start/stop.
    - `executables`: execution tokens (quoted paths + args, or relative helpers).
    - `tags`: arbitrary labels used for search (`"audio"`, `"office"`, `"dev"`).
    - `priority`: integer used for ordering (lower = earlier in the list).
    - `favorite`: `true`/`false` flag for quick filtering.
    - `hidden`: `true`/`false`; hidden workloads are not shown by default.
    - `aliases`: extra name variants used for search.
    - `intercepts` (optional): rules used by interceptor hooks.
  - At runtime, these values are projected into workload rows with metadata:
    - `Domain`, `Tags`, `Priority`, `Favorite`, `Hidden`, `Aliases`.

- **Grouping and alignment**
  - Each workload row is rendered with a fixed-width group label:
    - `"[Audio   ] DAW_Cubase"`, `"[Office  ] Office"`, etc.
  - The text inside `[...]` is always **8 characters wide**:
    - Short group names are padded with spaces on the right.
    - Long group names are truncated to 8 characters for display only.

### Tab 1 Keyboard Controls

While Tab 1 is active:

- **Navigation & toggle**
  - **`Up` / `Down`**: move the selection cursor.
  - **`Space`**: toggle the selected workload’s desired state between `Active` and `Inactive`.
  - **<code>`</code> (tilde key)**: cycle detail mode for workload rows:
    - `None` → `MixedOnly` → `All` → `None`.

- **Filters**
  - **`/`** (slash):
    - Opens an inline search prompt.
    - Matches against `Name`, `Domain`, `Tags`, and `Aliases`.
  - **`G`**:
    - Cycles the **Domain** filter through:
      - all groups → each individual domain → back to all.
  - **`F`**:
    - Toggles **Favorites-only** mode:
      - When on, only workloads with `favorite = true` are shown.
  - **`M`**:
    - Toggles **Mixed-only** mode:
      - When on, only workloads whose current state is `Mixed` are shown.

- **Hidden workloads**
  - When `hidden = true` on a workload:
    - It is **suppressed** from Tab 1 by default.
    - It will appear if and only if the current search query matches its:
      - `Name`, `Domain`, `Tags`, or `Aliases`.

The active filter state is always reflected in the Tab 1 footer, including:

- Current search query.
- Active domain filter (or `All`).
- Favorites-only and Mixed-only flags.

### Commit Behavior Modes

Dashboard commits now support two behaviors that can be toggled during runtime:

- **`CommitMode: Exit`** (default): pressing `Enter` commits changes and exits dashboard.
- **`CommitMode: Return`**: pressing `Enter` commits changes and shows:
  - `Press any key to return to dashboard. Press Esc to exit.`
  - any key except `Esc` returns to the dashboard and refreshes runtime state from disk.

Use **`R`** on any tab to toggle commit behavior mode.

### Windowed Rendering (Large Lists)

For large numbers of workloads, Tab 1 uses a **windowed renderer**:

- Only a slice of rows around the current cursor is drawn at once.
- This keeps the UI responsive and avoids flooding the console.
- The **description** line and optional **detail** lines always describe the *currently selected* workload, regardless of how many workloads exist off-screen.

This behavior is automatic – no extra configuration is required. As you add more domains and workloads to `App_Workloads`, the tab remains usable without changing your JSON schema.

### Settings and Actions (Tab 4)

Tab 4 now has two sections:

- **Settings**: persistent values staged and committed in batch.
- **Actions**: one-time operations that run exclusively (not bundled with pending setting changes).

For action rows (for example `Reset_Interceptors`):

- Press `Enter` once to arm confirmation (`Confirm: Enter`).
- Press `Enter` again on the same action row to run it.
- If settings are pending, action execution is blocked until settings are committed or reverted.

`Reset_Interceptors` is intended for stuck interceptor loops or broken interception state. It will:

- force `enable_interceptors = false` in `workspaces.json`,
- trigger orchestrator sync/cleanup of managed IFEO interceptor hooks,
- terminate active helper processes running `Interceptor.ps1` / `InterceptorPoll.ps1`.

Ownership safety is preserved during cleanup:

- Cleanup only targets WorkspaceManager-managed hooks (`WorkspaceManager_Managed = "1"`).
- Owner metadata (`WorkspaceManager_Owner`) is used when present to avoid touching non-project hooks.

To re-enable interception later, toggle `enable_interceptors` back to `true` in Tab 4 and commit normally.

