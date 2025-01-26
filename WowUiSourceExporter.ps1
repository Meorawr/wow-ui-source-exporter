#!/usr/bin/env pwsh
#Requires -Version 7.1

<#
.SYNOPSIS
    Exports UI source files for the current World of Warcraft build on the CDN.

.DESCRIPTION
    Exports UI source files for the current World of Warcraft build on the CDN.

    By default, this will perform an export for the current version on any
    listed product branch, but alternative builds can be queried via manual
    use of the BuildConfig and CDNConfig parameters.

.PARAMETER Product
    Specifies the game product to export UI source files for.

.PARAMETER OutputDirectory
    Specifies the root directory under which exported files will be placed.

.PARAMETER Region
    Specifies the CDN region to use for the export. Defaults to "us".

.PARAMETER ExportManifest
    If set, don't remove the manifest text files after exporting UI sources.

.PARAMETER ExportVersion
    If set, exports an additional "version.txt" file at the root of the output
    directory that contains the version number of the exported product.

.EXAMPLE
    PS> WowUiSourceExporter.ps1 -Product wow
#>

[CmdletBinding(PositionalBinding=$false)]
param (
    [Parameter(Mandatory)]
    [ValidateSet("wow", "wow_beta", "wow_classic", "wow_classic_beta", "wow_classic_ptr", "wow_classic_era", "wow_classic_era_beta", "wow_classic_era_ptr", "wowt", "wowxptr", "wowz")]
    [string] $Product,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $OutputDirectory,

    [Parameter()]
    [ValidateSet("us", "eu", "kr", "cn")]
    [string] $Region = "us",

    [Parameter()]
    [switch] $ExportManifest,

    [Parameter()]
    [switch] $ExportVersion
)

class FileLocation {
    [ValidateNotNullOrEmpty()] [int] $ID
    [ValidateNotNullOrEmpty()] [string] $Name
}

function Export-CDNFiles {
    [CmdletBinding(PositionalBinding=$false)]
    param (
        [Parameter(Mandatory, Position=0, ValueFromPipeline)]
        [FileLocation] $InputObject,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $OutputDirectory,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $BuildConfig,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $CDNConfig
    )

    begin {
        $InputFile = New-TemporaryFile
        $InputFileStream = [System.IO.StreamWriter]::new($InputFile)
    }

    process {
        $InputFileStream.WriteLine("$($InputObject.ID);$($InputObject.Name)")
    }

    end {
        try {
            $InputFileStream.Close()
            & TACTTool --buildconfig $BuildConfig --cdnconfig $CDNConfig --mode "list" --inputvalue $InputFile --output $OutputDirectory
        } finally {
            Remove-Item -Force -ErrorAction Ignore $InputFile
        }
    }
}

# Query the current product on the CDN. The output of this file isn't really
# anything like a CSV file, but it's column-delimited and so we can more or
# less pretend that it is one so long as we filter on the intended region
# to skip invalid lines.

$ProductInfo = Invoke-WebRequest "https://$Region.version.battle.net/$Product/versions" `
    | ConvertFrom-Csv -Delimiter "|" -Header "Region", "BuildConfig", "CDNConfig", "Keyring", "Build", "Version", "ProductConfig" `
    | Where-Object { $_.Region -eq $Region } `
    | Select-Object -First 1

# Next, we need to grab the textual manifest files from this build on the CDN.
# This consists of three files that list the filenames of Lua, XML, and TOC
# files in the interface.

$ManifestFiles = @(
    [FileLocation] @{ ID = 6067012; Name = "Interface/ui-code-list.txt" }
    [FileLocation] @{ ID = 6067013; Name = "Interface/ui-toc-list.txt" }
    [FileLocation] @{ ID = 6076661; Name = "Interface/ui-gen-addon-list.txt" }
)

$ManifestFiles | Export-CDNFiles -OutputDirectory $OutputDirectory -BuildConfig $ProductInfo.BuildConfig -CDNConfig $ProductInfo.CDNConfig

# With those downloaded we now need to work out the file IDs for each entry
# because (at present) TACTTool doesn't support filename-only exports
# for anything outside of the "install" set (eg. Wow.exe).
#
# For this we'll need to grab the community listfile and build a large hash
# table of Name => FDID.
#
# The listfile will be filtered to exclude any files outside the "Interface"
# directory tree as it's unlikely any export would request files from
# elsewhere, and this filtering speeds up the exports by a few seconds.
#
# Further, it's important to note that the listfile itself is formatted such
# that each filename is lowercased and uses "/" as a directory separator.

$FileLookup = @{}

Invoke-WebRequest "https://github.com/wowdev/wow-listfile/releases/latest/download/community-listfile.csv" `
    | ConvertFrom-Csv -Delimiter ";" -Header "ID", "Name" `
    | Where-Object { $_.Name -cmatch "^interface/" } `
    | ForEach-Object { $FileLookup[$_.Name] = $_.ID }

# Now that we've got the file lookup map, we can process the textual manifests
# and process the export of the UI source files themselves.
#
# As noted above, the file lookup table is keyed by a lowercased filename
# which uses "/" as a directory separator - this differs from what's present
# in the manifest file, so we need to do a bit of conversion work when doing
# the lookup. For the actual export however, we use the manifest-sourced
# name so that we don't lose the casing.

$ManifestFiles `
    | ForEach-Object { Get-Content (Join-Path $OutputDirectory $_.Name) } `
    | Sort-Object `
    | Get-Unique `
    | ForEach-Object {
        $FileID = $FileLookup[$_.ToLower().Replace("\", "/")]

        if ($FileID -ne $null) {
            [FileLocation] @{ ID = $FileID; Name = $_.Replace("\", "/") }
        }
    } `
    | Export-CDNFiles -OutputDirectory $OutputDirectory -BuildConfig $ProductInfo.BuildConfig -CDNConfig $ProductInfo.CDNConfig

# Export additional versioning metadata if we've been told to do so.

if ($ExportVersion) {
    Set-Content (Join-Path $OutputDirectory "version.txt") $ProductInfo.Version
}

# Clean up the textual manifests if we've not been told to keep them.

if (-not $ExportManifest) {
    $ManifestFiles | ForEach-Object { (Join-Path $OutputDirectory $_.Name) } | Remove-Item -Force -ErrorAction Ignore
}
