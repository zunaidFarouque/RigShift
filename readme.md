# WorkspaceManager

**Declarative Windows state:** one `workspaces.json` drives services, applications, power plans, registry, PnP devices, and optional **Image File Execution Options** launch interceptors. **Orchestrator.ps1** applies changes; **Dashboard.ps1** is a four-tab console UI for compliance, modes, overrides, and settings.

This repository is **BG-Services-Orchestrator**; user-facing text and shortcuts use the **WorkspaceManager** name. Managed IFEO registry hooks are tagged with owner **`BG-Services-Orchestrator`** (see [DOCs/Edge-Cases.md](DOCs/Edge-Cases.md)).

---

## Philosophy

Heavy desktop software leaves services and agents running after you close the UI. WorkspaceManager lets you declare **per-task** and **per-mode** machine state (DAW vs office vs low-latency stage) and switch it deliberately—without opaque “game booster” behavior.

---

## Core capabilities

- **Three-layer JSON model:** `Hardware_Definitions` (reusable components), `System_Modes` (power plan + target map), and `App_Workloads` (nested domains with services, executables, and optional intercepts).
- **Orchestrator:** Resolves `System_Modes` vs `App_Workloads` by name, syncs managed IFEO hooks when `_config.enable_interceptors` is true, and runs Start/Stop pipelines (see [DOCs/Orchestrator-Flow.md](DOCs/Orchestrator-Flow.md)).
- **Dashboard:** App workloads, system modes (when multiple modes exist), hardware compliance / overrides, and `_config` editing with commit batching and optional `CommitMode: Return` (**R**).
- **Execution tokens:** Quoted paths, repo-relative `'./…'`, `.lnk` / `.url` via ShellExecute, and command-style lines such as `gsudo taskkill …` (see [DOCs/Configuration.md](DOCs/Configuration.md)).
- **Shortcuts:** `Generate-Shortcuts.ps1` emits Start/Stop links for each **system mode** and each **app workload** name under `%APPDATA%\Microsoft\Windows\Start Menu\Programs\WorkspaceManager`.
- **Dashboard entry:** `Run-Dashboard.cmd` or `pwsh -File .\Create-DashboardShortcut.ps1` for a Desktop shortcut (optional `Assets\Dashboard.ico`).
- **Examples / scripts:** [Examples/](Examples/) and [CustomScripts/](CustomScripts/) for sample automation invoked via repo-relative execution tokens (see [DOCs/Configuration.md](DOCs/Configuration.md)).
- **PowerShell 7 + gsudo:** Orchestration assumes `pwsh` and elevated helpers where the scripts call `gsudo`.

---

## Prerequisites

1. **Windows 10 / 11**
2. **PowerShell 7** (`pwsh.exe`)
3. **[gsudo](https://github.com/gerardog/gsudo)** (recommended: `scoop install gsudo` then `gsudo config CacheMode Auto`)

---

## Quick start

**1. Clone the repository**

```powershell
git clone https://github.com/zunaidFarouque/WorkspaceManager.git
cd WorkspaceManager
```

The default folder name matches the GitHub repository name (`WorkspaceManager`). If you clone into a different directory, keep `workspaces.json` and the `.ps1` scripts together at the repo root.

**2. Edit `workspaces.json`**

Follow [DOCs/Configuration.md](DOCs/Configuration.md) (summary entry point: [SCHEMA.md](SCHEMA.md)). Minimal shape:

```json
{
  "_config": {
    "notifications": false,
    "enable_interceptors": false,
    "shortcut_prefix_start": "!Start-",
    "shortcut_prefix_stop": "!Stop-"
  },
  "Hardware_Definitions": {},
  "System_Modes": {
    "My_Mode": {
      "description": "Example",
      "power_plan": "Balanced",
      "targets": {}
    }
  },
  "App_Workloads": {
    "General": {
      "My_App": {
        "description": "Example workload",
        "services": [],
        "executables": [],
        "tags": [],
        "priority": 10,
        "favorite": false,
        "hidden": false,
        "aliases": []
      }
    }
  }
}
```

**3. (Optional) Generate Start Menu shortcuts**

```powershell
.\Generate-Shortcuts.ps1
```

**4. Run headless or open the Dashboard**

```powershell
gsudo pwsh -File .\Orchestrator.ps1 -WorkspaceName "My_Mode" -Action "Start"
```

```powershell
pwsh -File .\Dashboard.ps1
```

Optional desktop shortcut with icon: `pwsh -File .\Create-DashboardShortcut.ps1`

---

## Documentation

| Document | Topic |
|----------|--------|
| [SCHEMA.md](SCHEMA.md) | Pointer to full configuration reference |
| [DOCs/Configuration.md](DOCs/Configuration.md) | JSON schema, tokens, shortcuts, intercepts |
| [DOCs/Architecture.md](DOCs/Architecture.md) | Components and data flow |
| [DOCs/Orchestrator-Flow.md](DOCs/Orchestrator-Flow.md) | Orchestrator phases and parameters |
| [DOCs/Dashboard.md](DOCs/Dashboard.md) | Tabs, keys, commit behavior |
| [DOCs/Edge-Cases.md](DOCs/Edge-Cases.md) | Operational caveats |
| [DOCs/Audit.md](DOCs/Audit.md) | Doc ↔ implementation checklist |

**Tests:** Repository uses Pester (`*.Tests.ps1`). Run from the repo root with Pester installed, for example `Invoke-Pester`.

---

## License

Distributed under the MIT License. See [LICENSE](LICENSE) for details.
