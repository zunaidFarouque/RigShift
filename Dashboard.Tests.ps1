Set-StrictMode -Version Latest

Describe "Dashboard Commit Engine" {
    BeforeAll {
        $here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        . (Join-Path -Path $here -ChildPath "Dashboard.ps1")
    }

    It "invokes orchestrator only for actionable state transitions" {
        $uiStates = @(
            [pscustomobject]@{
                Name = "App1"
                CurrentState = "Stopped"
                DesiredState = "Ready"
                Type = "stateful"
            },
            [pscustomobject]@{
                Name = "App2"
                CurrentState = "Ready"
                DesiredState = "Stopped"
                Type = "stateful"
            },
            [pscustomobject]@{
                Name = "App3"
                CurrentState = "Ready"
                DesiredState = "Ready"
                Type = "stateful"
            },
            [pscustomobject]@{
                Name = "Cleanup"
                CurrentState = "Idle"
                DesiredState = "Run"
                Type = "oneshot"
            }
        )

        $mockOrchestratorPath = "C:\fake\Orchestrator.ps1"

        Mock -CommandName Start-Sleep -MockWith { }
        Mock -CommandName Invoke-OrchestratorScript -MockWith { }

        Invoke-WorkspaceCommit -UIStates $uiStates -OrchestratorPath $mockOrchestratorPath

        Assert-MockCalled -CommandName Invoke-OrchestratorScript -Times 3 -Exactly
        Assert-MockCalled -CommandName Invoke-OrchestratorScript -Times 1 -Exactly -ParameterFilter {
            $OrchestratorPath -eq $mockOrchestratorPath -and $WorkspaceName -eq "App1" -and $Action -eq "Start"
        }
        Assert-MockCalled -CommandName Invoke-OrchestratorScript -Times 1 -Exactly -ParameterFilter {
            $OrchestratorPath -eq $mockOrchestratorPath -and $WorkspaceName -eq "App2" -and $Action -eq "Stop"
        }
        Assert-MockCalled -CommandName Invoke-OrchestratorScript -Times 1 -Exactly -ParameterFilter {
            $OrchestratorPath -eq $mockOrchestratorPath -and $WorkspaceName -eq "Cleanup" -and $Action -eq "Start"
        }
    }
}

Describe "Get-WorkspaceRootPropertyValue" {
    BeforeAll {
        $here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        . (Join-Path -Path $here -ChildPath "Dashboard.ps1")
    }

    It "returns workspace object by exact name" {
        $inner = [pscustomobject]@{ x = 1 }
        $root = [pscustomobject]@{ MyWs = $inner }
        (Get-WorkspaceRootPropertyValue -Workspaces $root -WorkspaceName "MyWs") | Should -Be $inner
    }

    It "resolves name with OrdinalIgnoreCase fallback" {
        $inner = [pscustomobject]@{ x = 1 }
        $root = [pscustomobject]@{ System_Cleanup = $inner }
        (Get-WorkspaceRootPropertyValue -Workspaces $root -WorkspaceName "system_cleanup") | Should -Be $inner
    }

    It "returns null when workspace is absent" {
        $root = [pscustomobject]@{ Other = [pscustomobject]@{} }
        Get-WorkspaceRootPropertyValue -Workspaces $root -WorkspaceName "Missing" | Should -Be $null
    }

    It "returns null for blank name" {
        $root = [pscustomobject]@{ A = 1 }
        Get-WorkspaceRootPropertyValue -Workspaces $root -WorkspaceName "   " | Should -Be $null
    }
}

Describe "Get-DashboardPostCommitMessages" {
    BeforeAll {
        $here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        . (Join-Path -Path $here -ChildPath "Dashboard.ps1")
    }

    It "returns post_change and post_start lines for stateful Start commit" {
        $workspaces = [pscustomobject]@{
            App1 = [pscustomobject]@{
                post_change_message = "Verify devices."
                post_start_message  = "Open mixer."
            }
        }
        $uiStates = @(
            [pscustomobject]@{
                Name = "App1"
                Type = "stateful"
                CurrentState = "Stopped"
                DesiredState = "Ready"
            }
        )

        $result = @(Get-DashboardPostCommitMessages -UIStates $uiStates -Workspaces $workspaces)

        $result.Count | Should -Be 2
        $result[0] | Should -Be "[App1] Verify devices."
        $result[1] | Should -Be "[App1] Open mixer."
    }

    It "returns post_change and post_stop lines for stateful Stop commit" {
        $workspaces = [pscustomobject]@{
            App2 = [pscustomobject]@{
                post_change_message = "Profile winding down."
                post_stop_message   = "Save projects."
            }
        }
        $uiStates = @(
            [pscustomobject]@{
                Name = "App2"
                Type = "stateful"
                CurrentState = "Ready"
                DesiredState = "Stopped"
            }
        )

        $result = @(Get-DashboardPostCommitMessages -UIStates $uiStates -Workspaces $workspaces)

        $result.Count | Should -Be 2
        $result[0] | Should -Be "[App2] Profile winding down."
        $result[1] | Should -Be "[App2] Save projects."
    }

    It "treats oneshot Run as Start for post_start_message" {
        $workspaces = [pscustomobject]@{
            Cleanup = [pscustomobject]@{
                post_change_message = "Ran cleanup."
                post_start_message  = "Check logs."
            }
        }
        $uiStates = @(
            [pscustomobject]@{
                Name = "Cleanup"
                Type = "oneshot"
                CurrentState = "Idle"
                DesiredState = "Run"
            }
        )

        $result = @(Get-DashboardPostCommitMessages -UIStates $uiStates -Workspaces $workspaces)

        $result.Count | Should -Be 2
        $result[0] | Should -Be "[Cleanup] Ran cleanup."
        $result[1] | Should -Be "[Cleanup] Check logs."
    }

    It "returns nothing when desired Mixed would not invoke orchestrator" {
        $workspaces = [pscustomobject]@{
            MixedWs = [pscustomobject]@{
                post_change_message = "Should not show"
                post_start_message  = "Should not show"
                post_stop_message   = "Should not show"
            }
        }
        $uiStates = @(
            [pscustomobject]@{
                Name = "MixedWs"
                Type = "stateful"
                CurrentState = "Stopped"
                DesiredState = "Mixed"
            }
        )

        $result = @(Get-DashboardPostCommitMessages -UIStates $uiStates -Workspaces $workspaces)

        $result.Count | Should -Be 0
    }

    It "preserves UIStates order for multiple workspaces" {
        $workspaces = [pscustomobject]@{
            First = [pscustomobject]@{ post_change_message = "A" }
            Second = [pscustomobject]@{ post_change_message = "B" }
        }
        $uiStates = @(
            [pscustomobject]@{ Name = "First"; Type = "stateful"; CurrentState = "Stopped"; DesiredState = "Ready" },
            [pscustomobject]@{ Name = "Second"; Type = "stateful"; CurrentState = "Stopped"; DesiredState = "Ready" }
        )

        $result = @(Get-DashboardPostCommitMessages -UIStates $uiStates -Workspaces $workspaces)

        $result.Count | Should -Be 2
        $result[0] | Should -Be "[First] A"
        $result[1] | Should -Be "[Second] B"
    }
}

Describe "Dashboard desired-state keys (Space / Backspace)" {
    BeforeAll {
        $here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        . (Join-Path -Path $here -ChildPath "Dashboard.ps1")
    }

    It "when current is Mixed, Space toggles only Ready and Stopped" {
        Update-DashboardDesiredStateOnSpace -Type "stateful" -CurrentState "Mixed" -DesiredState "Mixed" | Should -Be "Ready"
        Update-DashboardDesiredStateOnSpace -Type "stateful" -CurrentState "Mixed" -DesiredState "Ready" | Should -Be "Stopped"
        Update-DashboardDesiredStateOnSpace -Type "stateful" -CurrentState "Mixed" -DesiredState "Stopped" | Should -Be "Ready"
    }

    It "Backspace on Mixed with desired Ready resets to Mixed" {
        Clear-DashboardDesiredState -Type "stateful" -CurrentState "Mixed" | Should -Be "Mixed"
    }

    It "Backspace on Ready with desired Stopped resets to Ready" {
        Clear-DashboardDesiredState -Type "stateful" -CurrentState "Ready" | Should -Be "Ready"
    }

    It "Backspace on oneshot clears Run to Idle" {
        Clear-DashboardDesiredState -Type "oneshot" -CurrentState "Idle" | Should -Be "Idle"
    }

    It "Space on non-Mixed stateful still toggles Ready and Stopped" {
        Update-DashboardDesiredStateOnSpace -Type "stateful" -CurrentState "Ready" -DesiredState "Ready" | Should -Be "Stopped"
        Update-DashboardDesiredStateOnSpace -Type "stateful" -CurrentState "Ready" -DesiredState "Stopped" | Should -Be "Ready"
    }
}

Describe "Dashboard Editor Helpers" {
    BeforeAll {
        $here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        . (Join-Path -Path $here -ChildPath "Dashboard.ps1")
    }

    It "builds editor items from actionable array properties" {
        $workspace = [pscustomobject]@{
            services            = @("Audiosrv")
            executables         = @("C:/Tools/App.exe")
            pnp_devices_disable = @("#*Camera*")
            tags                = @("Live_Stage")
        }

        $items = @(New-WorkspaceEditorItems -WorkspaceData $workspace)

        $items.Count | Should -Be 3
        @($items | Where-Object { $_.Property -eq "services" }).Count | Should -Be 1
        @($items | Where-Object { $_.Property -eq "executables" }).Count | Should -Be 1
        @($items | Where-Object { $_.Property -eq "pnp_devices_disable" }).Count | Should -Be 1
        @($items | Where-Object { $_.Property -eq "tags" }).Count | Should -Be 0
    }

    It "returns Object[] for a single item so Editor can use .Count under Windows PowerShell 5.1 StrictMode" {
        $workspace = [pscustomobject]@{
            scripts_start = @("'C:/x.bat'")
        }
        $raw = New-WorkspaceEditorItems -WorkspaceData $workspace
        $raw.GetType().Name | Should -Be "Object[]"
        $raw.Count | Should -Be 1
        $raw[0].Property | Should -Be "scripts_start"
    }

    It "returns empty Object[] when there are no actionable editor lines" {
        $workspace = [pscustomobject]@{ tags = @("only_tags") }
        $raw = New-WorkspaceEditorItems -WorkspaceData $workspace
        $raw.GetType().Name | Should -Be "Object[]"
        $raw.Count | Should -Be 0
    }

    It "toggles ignored marker and mutates RAM + disk for selected item" {
        $tempPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("dashboard-editor-{0}.json" -f ([guid]::NewGuid().ToString("N")))
        try {
            $workspaces = [pscustomobject]@{
                Audio_Production = [pscustomobject]@{
                    pnp_devices_disable = @("*Camera*")
                }
            }
            $selection = [pscustomobject]@{
                Property = "pnp_devices_disable"
                Index    = 0
                Value    = "*Camera*"
            }

            Set-WorkspaceEditorSelectionIgnored -Workspaces $workspaces -WorkspaceName "Audio_Production" -EditorSelection $selection -WorkspacePath $tempPath
            $workspaces.Audio_Production.pnp_devices_disable[0] | Should -Be "#*Camera*"
            $selection.Value | Should -Be "#*Camera*"

            Set-WorkspaceEditorSelectionIgnored -Workspaces $workspaces -WorkspaceName "Audio_Production" -EditorSelection $selection -WorkspacePath $tempPath
            $workspaces.Audio_Production.pnp_devices_disable[0] | Should -Be "*Camera*"
            $selection.Value | Should -Be "*Camera*"

            $saved = Get-Content -Path $tempPath -Raw | ConvertFrom-Json
            @($saved.Audio_Production.pnp_devices_disable).Count | Should -Be 1
        } finally {
            if (Test-Path -Path $tempPath) {
                Remove-Item -Path $tempPath -Force
            }
        }
    }

    It "filters or shows ignored details based on showIgnored toggle" {
        $workspace = [pscustomobject]@{
            services = @("Audiosrv", "#IgnoredService")
        }

        Mock -CommandName Get-Service -MockWith { [pscustomobject]@{ Status = "Running" } }
        Mock -CommandName Get-Process -MockWith { $null }
        Mock -CommandName powercfg -MockWith { "" }
        Mock -CommandName Get-ItemPropertyValue -MockWith { $null }

        $hidden = @(Get-WorkspaceDetails -WorkspaceData $workspace -PnpCache @() -ShowIgnored:$false -ShowStopHooks:$false)
        $shown = @(Get-WorkspaceDetails -WorkspaceData $workspace -PnpCache @() -ShowIgnored:$true -ShowStopHooks:$false)

        @($hidden | Where-Object { $_.Name -match "IgnoredService" }).Count | Should -Be 0
        @($shown | Where-Object { $_.Name -eq "[Ignored] IgnoredService" -and $_.IsRunning -eq $false }).Count | Should -Be 1
    }
}

Describe "Get-WorkspaceDetails executables" {
    BeforeAll {
        $here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        . (Join-Path -Path $here -ChildPath "Dashboard.ps1")
    }

    It "includes non-running executables in F1 details with IsRunning false" {
        $workspace = [pscustomobject]@{
            executables = @("C:/NotRunning.exe")
        }

        Mock -CommandName Get-Process -MockWith { $null }

        $details = @(Get-WorkspaceDetails -WorkspaceData $workspace -PnpCache @() -ShowIgnored:$false -ShowStopHooks:$false)
        $exeRows = @($details | Where-Object { $_.Type -eq "[Exe]" })
        $exeRows.Count | Should -Be 1
        $exeRows[0].Name | Should -Be "NotRunning.exe"
        $exeRows[0].IsRunning | Should -Be $false
    }

    It "derives executable name from quoted path when arguments follow" {
        $workspace = [pscustomobject]@{
            executables = @("'C:/Apps/My Tool.exe' --hidden")
        }

        Mock -CommandName Get-Process -MockWith { $null }

        $details = @(Get-WorkspaceDetails -WorkspaceData $workspace -PnpCache @() -ShowIgnored:$false -ShowStopHooks:$false)
        $exeRows = @($details | Where-Object { $_.Type -eq "[Exe]" })
        $exeRows.Count | Should -Be 1
        $exeRows[0].Name | Should -Be "My Tool.exe"
        $exeRows[0].IsRunning | Should -Be $false
    }
}

Describe "Get-WorkspaceDetails scripts_start and power_plan_start" {
    BeforeAll {
        $here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        . (Join-Path -Path $here -ChildPath "Dashboard.ps1")
    }

    It "lists scripts_start as stateless [Scr] rows with basename only" {
        $workspace = [pscustomobject]@{
            scripts_start = @("'./CustomScripts/Monitors 60hz.lnk'")
        }

        Mock -CommandName Get-Service -MockWith { $null }
        Mock -CommandName Get-Process -MockWith { $null }
        Mock -CommandName powercfg -MockWith { "" }
        Mock -CommandName Get-ItemPropertyValue -MockWith { $null }

        $details = @(Get-WorkspaceDetails -WorkspaceData $workspace -PnpCache @() -ShowIgnored:$false -ShowStopHooks:$false)
        $scrRows = @($details | Where-Object { $_.Type -eq "[Scr]" })
        $scrRows.Count | Should -Be 1
        $scrRows[0].Name | Should -Be "Monitors 60hz"
        $scrRows[0].IsRunning | Should -Be $null
    }

    It "skips commented and timer tokens in scripts_start" {
        $workspace = [pscustomobject]@{
            scripts_start = @("#'C:/Ignored.bat'", "t 3000", "'C:/Real.ps1'")
        }

        Mock -CommandName Get-Service -MockWith { $null }
        Mock -CommandName Get-Process -MockWith { $null }
        Mock -CommandName powercfg -MockWith { "" }
        Mock -CommandName Get-ItemPropertyValue -MockWith { $null }

        $details = @(Get-WorkspaceDetails -WorkspaceData $workspace -PnpCache @() -ShowIgnored:$false -ShowStopHooks:$false)
        $scrRows = @($details | Where-Object { $_.Type -eq "[Scr]" })
        $scrRows.Count | Should -Be 1
        $scrRows[0].Name | Should -Be "Real"
    }

    It "includes power_plan_start with monitored IsRunning from powercfg" {
        $workspace = [pscustomobject]@{
            power_plan_start = "Max Performance"
        }

        Mock -CommandName Get-Service -MockWith { $null }
        Mock -CommandName Get-Process -MockWith { $null }
        Mock -CommandName powercfg -MockWith { "Power Scheme GUID: x  (Max Performance)" }
        Mock -CommandName Get-ItemPropertyValue -MockWith { $null }

        $details = @(Get-WorkspaceDetails -WorkspaceData $workspace -PnpCache @() -ShowIgnored:$false -ShowStopHooks:$false)
        $pwrRows = @($details | Where-Object { $_.Type -eq "[Pwr]" })
        $pwrRows.Count | Should -Be 1
        $pwrRows[0].Name | Should -Be "Max Performance"
        $pwrRows[0].IsRunning | Should -Be $true
    }

    It "lists services_disable as [Off] with IsRunning true when service is not Running" {
        $workspace = [pscustomobject]@{
            services_disable = @("WSearch")
        }

        Mock -CommandName Get-Service -MockWith { [pscustomobject]@{ Status = "Stopped" } }
        Mock -CommandName Get-Process -MockWith { $null }
        Mock -CommandName powercfg -MockWith { "" }
        Mock -CommandName Get-ItemPropertyValue -MockWith { $null }

        $details = @(Get-WorkspaceDetails -WorkspaceData $workspace -PnpCache @() -ShowIgnored:$false -ShowStopHooks:$false)
        $offRows = @($details | Where-Object { $_.Type -eq "[Off]" })
        $offRows.Count | Should -Be 1
        $offRows[0].Name | Should -Be "WSearch"
        $offRows[0].IsRunning | Should -Be $true
    }

    It "lists scripts_stop as [ScrStop] with stateless IsRunning" {
        $workspace = [pscustomobject]@{
            scripts_stop = @("'C:/Tools/Cleanup.bat'")
        }

        Mock -CommandName Get-Service -MockWith { $null }
        Mock -CommandName Get-Process -MockWith { $null }
        Mock -CommandName powercfg -MockWith { "" }
        Mock -CommandName Get-ItemPropertyValue -MockWith { $null }

        $details = @(Get-WorkspaceDetails -WorkspaceData $workspace -PnpCache @() -ShowIgnored:$false -ShowStopHooks:$true)
        $rows = @($details | Where-Object { $_.Type -eq "[ScrStop]" })
        $rows.Count | Should -Be 1
        $rows[0].Name | Should -Be "Cleanup"
        $rows[0].IsRunning | Should -Be $null
    }

    It "lists power_plan_stop as [PwrStop] stateless" {
        $workspace = [pscustomobject]@{
            power_plan_stop = "Balanced"
        }

        Mock -CommandName Get-Service -MockWith { $null }
        Mock -CommandName Get-Process -MockWith { $null }
        Mock -CommandName powercfg -MockWith { "" }
        Mock -CommandName Get-ItemPropertyValue -MockWith { $null }

        $details = @(Get-WorkspaceDetails -WorkspaceData $workspace -PnpCache @() -ShowIgnored:$false -ShowStopHooks:$true)
        $rows = @($details | Where-Object { $_.Type -eq "[PwrStop]" })
        $rows.Count | Should -Be 1
        $rows[0].Name | Should -Be "Balanced"
        $rows[0].IsRunning | Should -Be $null
    }

    It "omits [ScrStop] and [PwrStop] when ShowStopHooks is false" {
        $workspace = [pscustomobject]@{
            scripts_stop     = @("'C:/Tools/Cleanup.bat'")
            power_plan_stop  = "Balanced"
        }

        Mock -CommandName Get-Service -MockWith { $null }
        Mock -CommandName Get-Process -MockWith { $null }
        Mock -CommandName powercfg -MockWith { "" }
        Mock -CommandName Get-ItemPropertyValue -MockWith { $null }

        $details = @(Get-WorkspaceDetails -WorkspaceData $workspace -PnpCache @() -ShowIgnored:$false -ShowStopHooks:$false)
        @($details | Where-Object { $_.Type -eq "[ScrStop]" -or $_.Type -eq "[PwrStop]" }).Count | Should -Be 0
    }
}

Describe "Get-UIStatesFromWorkspaces description" {
    BeforeAll {
        $here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        . (Join-Path -Path $here -ChildPath "Dashboard.ps1")
        # Mandatory [array] PnpCache rejects @(); use a stub entry (workspaces under test have no PnP patterns).
        $script:PnpCacheStub = @([pscustomobject]@{ Name = "__PesterPnpStub__"; Status = "OK" })
    }

    It "maps workspace description to Description on UI state" {
        $workspaces = [pscustomobject]@{
            ProfileA = [pscustomobject]@{ description = "Primary DAW profile for recording." }
        }
        $states = @(Get-UIStatesFromWorkspaces -Workspaces $workspaces -PnpCache $script:PnpCacheStub -ShowIgnored:$false -ShowStopHooks:$false)
        $states.Count | Should -Be 1
        $states[0].Name | Should -Be "ProfileA"
        $states[0].Description | Should -Be "Primary DAW profile for recording."
    }

    It "uses empty string when description property is absent" {
        $workspaces = [pscustomobject]@{
            ProfileB = [pscustomobject]@{ type = "stateful" }
        }
        $states = @(Get-UIStatesFromWorkspaces -Workspaces $workspaces -PnpCache $script:PnpCacheStub -ShowIgnored:$false -ShowStopHooks:$false)
        $states[0].Description | Should -Be ""
    }

    It "preserves whitespace-only description for UI layer to treat as empty" {
        $workspaces = [pscustomobject]@{
            ProfileC = [pscustomobject]@{ description = "   " }
        }
        $states = @(Get-UIStatesFromWorkspaces -Workspaces $workspaces -PnpCache $script:PnpCacheStub -ShowIgnored:$false -ShowStopHooks:$false)
        $states[0].Description | Should -Be "   "
    }
}
