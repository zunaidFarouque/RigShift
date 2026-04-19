Set-StrictMode -Version Latest

Describe "ExecutionTokenPath" {
    BeforeAll {
        $basePath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $script:repoRoot = Split-Path -Path $basePath -Parent
        $script:scriptsDir = Join-Path -Path $script:repoRoot -ChildPath "Scripts"
        . (Join-Path -Path $script:scriptsDir -ChildPath "ExecutionTokenPath.ps1")
    }

    BeforeEach {
        $script:testRepo = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("rigshift-etp-{0}" -f [Guid]::NewGuid().ToString("n"))
        New-Item -ItemType Directory -Path $script:testRepo -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRepo) {
            Remove-Item -LiteralPath $script:testRepo -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "expands quoted relative token against RepoRoot" {
        $nested = Join-Path $script:testRepo "CustomScripts\tool.exe"
        New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($nested)) -Force | Out-Null
        New-Item -ItemType File -Path $nested -Force | Out-Null
        $tok = "'./CustomScripts/tool.exe' -q"
        $info = Get-ExecutionTokenFilesystemCheckInfo -RepoRoot $script:testRepo -ExecutionToken $tok
        $info.RequiresPathCheck | Should -Be $true
        $info.PathExists | Should -Be $true
        $info.ArgumentList.Trim() | Should -Be "-q"
    }

    It "marks PathExists false when resolved path is missing" {
        $tok = "'./CustomScripts/does-not-exist.exe'"
        $info = Get-ExecutionTokenFilesystemCheckInfo -RepoRoot $script:testRepo -ExecutionToken $tok
        $info.RequiresPathCheck | Should -Be $true
        $info.PathExists | Should -Be $false
    }

    It "does not require path check for bare command-style token" {
        $info = Get-ExecutionTokenFilesystemCheckInfo -RepoRoot $script:testRepo -ExecutionToken "gsudo taskkill /F /IM x.exe"
        $info.RequiresPathCheck | Should -Be $false
        $info.FilePathForLaunch | Should -Be "gsudo"
        $info.PathExists | Should -Be $true
    }

    It "requires path check for drive-letter path" {
        $drivePath = Join-Path $script:testRepo "app.exe"
        New-Item -ItemType File -Path $drivePath -Force | Out-Null
        $unix = $drivePath.Replace("\", "/")
        $info = Get-ExecutionTokenFilesystemCheckInfo -RepoRoot $script:testRepo -ExecutionToken $unix
        $info.RequiresPathCheck | Should -Be $true
        $info.PathExists | Should -Be $true
    }
}
