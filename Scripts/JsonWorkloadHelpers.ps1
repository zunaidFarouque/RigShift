function Get-JsonObjectOptionalStringArray {
    <#
    .SYNOPSIS
        Reads an optional JSON array (or scalar) property from a PSCustomObject without strict-mode errors when the property is missing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [psobject]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    if ($null -eq $InputObject) {
        return @()
    }

    $prop = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -eq $prop) {
        return @()
    }

    $value = $prop.Value
    if ($null -eq $value) {
        return @()
    }

    if ($value -is [System.Array]) {
        return @($value | ForEach-Object { [string]$_ })
    }

    return @([string]$value)
}
