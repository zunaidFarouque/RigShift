Set-StrictMode -Version Latest

function Resolve-ExecutionTokenQuotedRelative {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ExecutionToken
    )

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        throw "Resolve-ExecutionTokenQuotedRelative: RepoRoot is required."
    }

    $root = $RepoRoot
    $sep = [System.IO.Path]::DirectorySeparatorChar
    [regex]::Replace($ExecutionToken, "^'\.[\/\\](.*?)'", {
        param($match)
        $relativeRemainder = $match.Groups[1].Value -replace '/', $sep
        "'" + (Join-Path $root $relativeRemainder) + "'"
    })
}

function Resolve-ExecutionTokenRepoRelativeFilePath {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        throw "Resolve-ExecutionTokenRepoRelativeFilePath: RepoRoot is required."
    }

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    $t = $Path.Trim()
    if ($t.Length -ge 2 -and $t[0] -eq [char]'.' -and ($t[1] -eq [char]'/' -or $t[1] -eq '\')) {
        $rest = $t.Substring(2).TrimStart([char[]]@('/', '\'))
        $rest = $rest -replace '/', [System.IO.Path]::DirectorySeparatorChar
        return (Join-Path $RepoRoot $rest)
    }

    return $Path
}

function Get-ExecutionTokenFilesystemCheckInfo {
    <#
    .SYNOPSIS
        Parses an execution token the same way as Orchestrator Invoke-ExecutionToken and reports whether a
        filesystem existence check applies and whether the resolved path exists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$ExecutionToken
    )

    $token = Resolve-ExecutionTokenQuotedRelative -RepoRoot $RepoRoot -ExecutionToken $ExecutionToken
    $filePath = $token
    $argumentList = ""
    $tokenWasQuotedPath = $false
    if ($token -match "^'(.*?)'\s*(.*)$") {
        $filePath = $matches[1]
        $argumentList = $matches[2]
        $tokenWasQuotedPath = $true
    } elseif ($token -match "^(\S+)\s+(.+)$") {
        $filePath = $matches[1]
        $argumentList = $matches[2]
    }

    $shouldResolveAsPath = $tokenWasQuotedPath -or
        $filePath.StartsWith(".\") -or
        $filePath.StartsWith("./") -or
        $filePath -match '^[a-zA-Z]:[\\/]' -or
        $filePath.Contains("\") -or
        $filePath.Contains("/")

    if ($shouldResolveAsPath) {
        $resolved = Resolve-ExecutionTokenRepoRelativeFilePath -RepoRoot $RepoRoot -Path $filePath
        $full = [System.IO.Path]::GetFullPath($resolved)
        $exists = Test-Path -LiteralPath $full
        return [pscustomobject]@{
            RequiresPathCheck = $true
            ResolvedFullPath  = $full
            FilePathForLaunch = $full
            ArgumentList      = $argumentList
            PathExists        = $exists
        }
    }

    return [pscustomobject]@{
        RequiresPathCheck = $false
        ResolvedFullPath  = ""
        FilePathForLaunch = $filePath
        ArgumentList      = $argumentList
        PathExists        = $true
    }
}
