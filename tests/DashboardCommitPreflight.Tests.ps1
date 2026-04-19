Set-StrictMode -Version Latest

Describe "Dashboard commit preflight" {
    BeforeAll {
        $basePath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $script:repoRoot = Split-Path -Path $basePath -Parent
        $script:scriptsDir = Join-Path -Path $script:repoRoot -ChildPath "Scripts"
        . (Join-Path -Path $script:scriptsDir -ChildPath "Dashboard.ps1")
    }

    It "Get-DashboardCommitPreflightIssues reports disabled service on Start ServicesOnly" {
        $workspaces = [pscustomobject]@{
            Hardware_Definitions = [pscustomobject]@{}
            System_Modes = [pscustomobject]@{}
            App_Workloads = [pscustomobject]@{
                Office = [pscustomobject]@{
                    Office = [pscustomobject]@{ services = @("ClickToRunSvc"); executables = @() }
                }
            }
        }
        $op = [pscustomobject]@{
            Phase = 6; WorkspaceName = "Office"; ProfileType = "App_Workload"; Action = "Start"; ExecutionScope = "ServicesOnly"; Reason = "Start Office"
        }
        Mock -CommandName Get-Service -MockWith {
            return [pscustomobject]@{
                Name      = "ClickToRunSvc"
                StartType = [System.ServiceProcess.ServiceStartMode]::Disabled
            }
        } -ParameterFilter { $Name -eq "ClickToRunSvc" }

        $issues = @(Get-DashboardCommitPreflightIssues -Operations @($op) -Workspaces $workspaces -RepoRoot $script:repoRoot)
        $issues.Count | Should -Be 1
        $issues[0].Category | Should -Be "ServiceDisabled"
        $issues[0].ServiceName | Should -Be "ClickToRunSvc"
    }

    It "Get-DashboardCommitPreflightIssues reports missing path-backed executable" {
        $workspaces = [pscustomobject]@{
            Hardware_Definitions = [pscustomobject]@{}
            System_Modes = [pscustomobject]@{}
            App_Workloads = [pscustomobject]@{
                Office = [pscustomobject]@{
                    Office = [pscustomobject]@{ services = @(); executables = @("'\./CustomScripts/no-such-preflight.exe'") }
                }
            }
        }
        $op = [pscustomobject]@{
            Phase = 7; WorkspaceName = "Office"; ProfileType = "App_Workload"; Action = "Start"; ExecutionScope = "ExecutablesOnly"; Reason = "Start Office"
        }

        $issues = @(Get-DashboardCommitPreflightIssues -Operations @($op) -Workspaces $workspaces -RepoRoot $script:repoRoot)
        $issues.Count | Should -Be 1
        $issues[0].Category | Should -Be "NotFound"
        $issues[0].ResolvedPath | Should -Match "no-such-preflight"
    }

    It "Resolve-DashboardCommitPreflightDecisions aborts when policy is non-interactive Abort" {
        $workspaces = [pscustomobject]@{
            _config = [pscustomobject]@{ commit_error_policy = "Prompt" }
        }
        $issues = @(
            [pscustomobject]@{
                OperationKey = "6|X|App_Workload|Start|ServicesOnly"
                Category = "NotFound"
                Message = "missing"
                ServiceName = ""
                ExecutionToken = ""
                ResolvedPath = ""
            }
        )
        Mock -CommandName Test-DashboardInteractiveInputAvailable -MockWith { $false }

        $r = Resolve-DashboardCommitPreflightDecisions -Issues $issues -Workspaces $workspaces -ReadKeyScript $null
        $r.Continue | Should -Be $false
        @($r.ByOperationKey.Keys).Count | Should -Be 0
    }

    It "Resolve-DashboardCommitPreflightDecisions invokes Set-Service manual when user selects option 3" {
        $workspaces = [pscustomobject]@{
            _config = [pscustomobject]@{ commit_error_policy = "Prompt" }
        }
        $issues = @(
            [pscustomobject]@{
                OperationKey = "6|Office|App_Workload|Start|ServicesOnly"
                Category = "ServiceDisabled"
                Message = "disabled"
                ServiceName = "ClickToRunSvc"
                ExecutionToken = ""
                ResolvedPath = ""
            }
        )
        Mock -CommandName Test-DashboardInteractiveInputAvailable -MockWith { $true }
        Mock -CommandName Invoke-DashboardSetServiceStartupManual -MockWith { }
        $readKey = { [pscustomobject]@{ KeyChar = '3'; Key = [ConsoleKey]::D3 } }

        $r = Resolve-DashboardCommitPreflightDecisions -Issues $issues -Workspaces $workspaces -ReadKeyScript $readKey
        $r.Continue | Should -Be $true
        Assert-MockCalled -CommandName Invoke-DashboardSetServiceStartupManual -Times 1 -Exactly -ParameterFilter {
            $ServiceName -eq "ClickToRunSvc"
        }
    }

    It "Resolve-DashboardCommitPreflightDecisions skips all affected operations when policy is Skip" {
        $workspaces = [pscustomobject]@{
            _config = [pscustomobject]@{ commit_error_policy = "Skip" }
        }
        $issues = @(
            [pscustomobject]@{
                OperationKey = "6|X|App_Workload|Start|ServicesOnly"
                Category = "NotFound"
                Message = "missing"
                ServiceName = ""
                ExecutionToken = ""
                ResolvedPath = ""
            }
        )

        $r = Resolve-DashboardCommitPreflightDecisions -Issues $issues -Workspaces $workspaces -ReadKeyScript $null
        $r.Continue | Should -Be $true
        $r.ByOperationKey["6|X|App_Workload|Start|ServicesOnly"] | Should -Be "SkipOperation"
    }

    It "Invoke-DashboardCommitOperations skips invoke when preflight marked SkipOperation" {
        $workspaces = [pscustomobject]@{
            _config = [pscustomobject]@{ commit_error_policy = "Prompt" }
            App_Workloads = [pscustomobject]@{
                Office = [pscustomobject]@{
                    Office = [pscustomobject]@{ services = @("ClickToRunSvc"); executables = @("ONEDRIVE") }
                }
            }
            Hardware_Definitions = [pscustomobject]@{}
            System_Modes = [pscustomobject]@{}
        }
        $operations = @(
            [pscustomobject]@{ Phase = 6; WorkspaceName = "Office"; ProfileType = "App_Workload"; Action = "Start"; ExecutionScope = "ServicesOnly"; Reason = "Start Office" },
            [pscustomobject]@{ Phase = 7; WorkspaceName = "Office"; ProfileType = "App_Workload"; Action = "Start"; ExecutionScope = "ExecutablesOnly"; Reason = "Start Office" }
        )
        $key6 = Get-DashboardCommitOperationKey -Operation $operations[0]
        $pref = @{ $key6 = "SkipOperation" }

        Mock -CommandName Invoke-OrchestratorScript -MockWith { }
        Mock -CommandName Start-Sleep -MockWith { }
        Mock -CommandName Write-Host -MockWith { }

        $result = @(Invoke-DashboardCommitOperations -Operations $operations -OrchestratorPath "C:\fake\Orchestrator.ps1" -Workspaces $workspaces -PreflightDecisionsByOperationKey $pref)

        Assert-MockCalled -CommandName Invoke-OrchestratorScript -Times 1 -Exactly
        $result[0].Result | Should -Be "Skipped"
        $result[0].FailureCategory | Should -Be "PreflightSkipped"
        $result[1].Result | Should -Be "Done"
    }

    It "Invoke-DashboardCommitFlow cancels before Invoke-DashboardCommit when preflight aborts" {
        $workloads = @(
            [pscustomobject]@{ Name = "Office"; CurrentState = "Inactive"; DesiredState = "Active"; ProfileType = "App_Workload"; Domain = "Office" }
        )
        $modes = @(
            [pscustomobject]@{ Name = "Eco_Life"; CurrentState = "Active"; DesiredState = "Active"; ProfileType = "System_Mode" }
        )
        $queue = @{}
        $workspaces = [pscustomobject]@{
            _config = [pscustomobject]@{ commit_error_policy = "Prompt" }
            System_Modes = [pscustomobject]@{ Eco_Life = [pscustomobject]@{} }
            Hardware_Definitions = [pscustomobject]@{}
            App_Workloads = [pscustomobject]@{
                Office = [pscustomobject]@{
                    Office = [pscustomobject]@{ services = @("ClickToRunSvc"); executables = @("x.exe") }
                }
            }
        }
        $settingsRows = @()

        Mock -CommandName Invoke-SafeClearHost -MockWith { }
        Mock -CommandName Save-DashboardStateMemory -MockWith { }
        Mock -CommandName Invoke-DashboardCommit -MockWith { }
        Mock -CommandName Get-DashboardPostCommitMessages -MockWith { @() }
        Mock -CommandName Get-DashboardCommitPreflightIssues -MockWith {
            return @(
                [pscustomobject]@{
                    OperationKey = "6|Office|App_Workload|Start|ServicesOnly"
                    Category = "ServiceDisabled"
                    Message = "disabled"
                    ServiceName = "ClickToRunSvc"
                    ExecutionToken = ""
                    ResolvedPath = ""
                }
            )
        }
        Mock -CommandName Test-DashboardInteractiveInputAvailable -MockWith { $false }

        $result = Invoke-DashboardCommitFlow `
            -WorkloadStates $workloads `
            -ModeStates $modes `
            -PendingHardwareChanges $queue `
            -OrchestratorPath "C:\fake\Orchestrator.ps1" `
            -StateFilePath "C:\fake\state.json" `
            -JsonPath "C:\fake\workspaces.json" `
            -Workspaces $workspaces `
            -SettingsRows $settingsRows `
            -CommitMode "Return" `
            -ReadKeyScript { return [pscustomobject]@{ Key = [ConsoleKey]::Enter } }

        $result | Should -Be "ReturnToDashboard"
        Assert-MockCalled -CommandName Invoke-DashboardCommit -Times 0 -Exactly
    }
}
