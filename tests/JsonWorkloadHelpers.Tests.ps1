Set-StrictMode -Version Latest

Describe "JsonWorkloadHelpers" {
    BeforeAll {
        $basePath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $script:repoRoot = Split-Path -Path $basePath -Parent
        $script:scriptsDir = Join-Path -Path $script:repoRoot -ChildPath "Scripts"
        . (Join-Path -Path $script:scriptsDir -ChildPath "JsonWorkloadHelpers.ps1")
    }

    It "returns empty array when property is missing" {
        $o = [pscustomobject]@{ other = 1 }
        @(Get-JsonObjectOptionalStringArray -InputObject $o -PropertyName "services").Count | Should -Be 0
    }

    It "returns single-element array for scalar string property" {
        $o = [pscustomobject]@{ services = "OneSvc" }
        $a = @(Get-JsonObjectOptionalStringArray -InputObject $o -PropertyName "services")
        $a.Count | Should -Be 1
        $a[0] | Should -Be "OneSvc"
    }

    It "returns array for JSON-style string array property" {
        $o = [pscustomobject]@{ executables = @("a.exe", "b.exe") }
        $a = @(Get-JsonObjectOptionalStringArray -InputObject $o -PropertyName "executables")
        $a.Count | Should -Be 2
    }
}
