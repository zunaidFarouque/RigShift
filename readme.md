# RigShift

<p align="center">
  <img src="Assets/Social Preview.png" alt="RigShift social preview banner" width="900" />
</p>

**Declarative bare-metal orchestration for Windows.**

RigShift lets you define machine state as code and switch contexts safely: services, processes, power plans, registry values, PnP devices, and optional launch interception.  
One file, `Scripts\workspaces.json`, declares exactly what should be ON, OFF, or conditional for each workflow.

It is built for power users who demand deterministic environments (live audio, software dev, hardcore gaming, battery preservation, kiosk modes) without permanent OS mutilation or black-box "booster" tools.

## Why RigShift

Modern Windows is optimized for general-purpose computing, not sterile task isolation. Background services, update activity, device polling, and telemetry run relentlessly—introducing DPC latency spikes, hardware contention, and unpredictable side effects exactly when you can least afford them.

Standard "debloat" scripts permanently break core OS functionality. Consumer "game boosters" blindly kill random tasks. RigShift is a scalpel. It provides:

- **Declarative State Enforcement** instead of fragile, one-off batch scripts.
- **Reversible Transitions** between explicitly named, hardware-locked contexts.
- **Bare-Metal Control** with direct service, process, PnP device, and power operations.
- **Practical Safety Rails** through tested teardown behavior, RAM protection, and explicit documentation.

## Core capabilities

- **Dashboard TUI** (`Scripts\Dashboard.ps1`) for interactive context switching, compliance checks, and config commits.
- **Headless Orchestration** (`Scripts\Orchestrator.ps1`, via `Orchestrator.cmd`) for rapid automation and scripting workflows.
- **Modular Configuration Domains** via `_config`, `Hardware_Definitions`, `System_Modes`, and `App_Workloads`.
- **Optional IFEO Interceptors** for pre-launch priming and managed hook lifecycles.
- **Shortcut Generation and Setup Helpers** for frictionless day-to-day usage.
- **Zero External Runtime Framework** beyond native PowerShell and standard Windows tooling.

## Architecture at a glance

```mermaid
flowchart LR
    workspacesJson["Scripts/workspaces.json"] --> orchestrator["Scripts/Orchestrator.ps1"]
    workspacesJson --> dashboard["Scripts/Dashboard.ps1"]
    workspacesJson --> workspaceState["Scripts/WorkspaceState.ps1"]
    orchestrator --> windowsState["Windows State"]
    dashboard --> orchestrator
    workspaceState --> dashboard
    windowsState --> services["Services/Processes"]
    windowsState --> systemCfg["Power/Registry/PnP"]
    windowsState --> ifeo["IFEO Interceptors"]
````

## Prerequisites

1.  Windows 10 or 11
2.  PowerShell 7 (`pwsh.exe`)
3.  [gsudo](https://github.com/gerardog/gsudo) (Highly recommended for seamless UAC elevation)

**Recommended install:**

```powershell
scoop install gsudo
gsudo config CacheMode Auto
```

*Note: Machine-state operations are elevated through `gsudo` in the relevant script paths.*

## Quick start

1.  Clone and enter the repository:

<!-- end list -->

```powershell
git clone [https://github.com/zunaidFarouque/RigShift.git](https://github.com/zunaidFarouque/RigShift.git)
cd RigShift
```

2.  Create or edit `Scripts\workspaces.json`:

<!-- end list -->

```json
{
  "_config": {},
  "Hardware_Definitions": {},
  "System_Modes": {},
  "App_Workloads": {}
}
```

3.  Optional setup helper (creates `RigShift Dashboard.lnk` at the repo root and can add Desktop/Start Menu shortcuts):

<!-- end list -->

```powershell
.\Setup.cmd
```

4.  Optional: generate headless Start Menu shortcuts:

<!-- end list -->

```powershell
.\Generate-Shortcuts.cmd
```

5.  Launch the dashboard to manage states interactively:

<!-- end list -->

```powershell
.\Scripts\Run-Dashboard.cmd
```

6.  Or, run orchestration directly via CLI:

<!-- end list -->

```powershell
.\Orchestrator.cmd -WorkspaceName "My_Mode" -Action "Start"
```

*Note: When using the dashboard, `Scripts\state.json` is written beside `Scripts\workspaces.json` to persist mode blueprint state.*

## Configuration model

  - `_config` controls global behavior such as notifications, interceptor sync, poll timeout, and shortcut prefixes.
  - `Hardware_Definitions` is the reusable component catalog (service, registry, PnP device, process, stateless, or scripted overrides).
  - `System_Modes` defines power plan and desired ON/OFF/ANY state per component.
  - `App_Workloads` defines nested domains and workloads with services, executables, tags, aliases, and optional intercept rules.

Complete schema and token rules: [DOCs/Configuration.md](https://www.google.com/search?q=DOCs/Configuration.md)

## Shortcuts, icons, and branding notes

  - `Generate-Shortcuts.cmd` creates Start/Stop shortcuts in `%APPDATA%\Microsoft\Windows\Start Menu\Programs\RigShift`.
  - If `Assets\Dashboard.ico` exists, generated `.lnk` files use it in Explorer.
  - `.cmd` files cannot carry custom Explorer icons by themselves; use `.lnk` launchers for branded tiles.
  - For Windows Terminal tab/taskbar branding, configure a profile icon as described in [DOCs/Windows-Terminal.md](https://www.google.com/search?q=DOCs/Windows-Terminal.md).

**GitHub social preview:** Upload `Assets\Social Preview.png` in repository **Settings → General → Social preview** to match this README banner in link cards.

## Documentation

| Document | Topic |
|----------|-------|
| [DOCs/Architecture.md](https://www.google.com/search?q=DOCs/Architecture.md) | Components, boundaries, naming, and runtime model |
| [DOCs/Configuration.md](https://www.google.com/search?q=DOCs/Configuration.md) | JSON schema, tokens, intercept rules, and shortcut behavior |
| [DOCs/Orchestrator-Flow.md](https://www.google.com/search?q=DOCs/Orchestrator-Flow.md) | Parameters, phases, routing, and execution order |
| [DOCs/Dashboard.md](https://www.google.com/search?q=DOCs/Dashboard.md) | Tab behavior, keybindings, commit flow, and actions |
| [DOCs/Edge-Cases.md](https://www.google.com/search?q=DOCs/Edge-Cases.md) | Operational caveats, risks, and mitigations |
| [DOCs/Audit.md](https://www.google.com/search?q=DOCs/Audit.md) | Doc-to-implementation verification matrix |
| [DOCs/Windows-Terminal.md](https://www.google.com/search?q=DOCs/Windows-Terminal.md) | Optional Windows Terminal icon profile |

## Testing

Pester tests serve as behavioral contracts for core components:

  - `tests\Orchestrator.Tests.ps1`
  - `tests\Dashboard.Tests.ps1`
  - `tests\WorkspaceState.Tests.ps1`
  - `tests\Interceptor.Tests.ps1`

Run from repository root:

```powershell
Invoke-Pester -OutputFormat NUnitXml -OutputFile .\tests\testResults.xml
```

## Limitations and safety notes

  - Shared services across workloads are not dependency-resolved globally; commit order can matter when profiles overlap.
  - Workload stop operations use `taskkill` by executable leaf name and can terminate unsaved applications.
  - Workload names should be unique across all `App_Workloads` domains to avoid ambiguous resolution.
  - IFEO-based interception can interact with endpoint security policy; disable interceptors while troubleshooting policy conflicts.

## License

Distributed under the MIT License. See [LICENSE](https://www.google.com/search?q=LICENSE).

