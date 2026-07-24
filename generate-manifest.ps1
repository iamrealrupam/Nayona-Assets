# Generates manifest.json for Nayona-Assets with validated SHA-256 checksums.
#
# Normal workflow (edit local assets, then publish):
#   .\generate-manifest.ps1
#   .\generate-manifest.ps1 -VerifyRemote
#   .\push.ps1
#
# Fix manifest only (GitHub files already correct, manifest checksums wrong):
#   .\generate-manifest.ps1 -RemoteAsSource
#
# Fail CI / pre-push when local != GitHub:
#   .\generate-manifest.ps1 -VerifyRemote -FailOnRemoteMismatch

[CmdletBinding()]
param(
    [string]$ManifestVersion = "1.0.2",
    [string]$QuotesVersion,
    [string]$RemoteBaseUrl = "https://raw.githubusercontent.com/iamrealrupam/Nayona-Assets/main",
    [switch]$VerifyRemote,
    [switch]$RemoteAsSource,
    [switch]$FailOnRemoteMismatch
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$manifestPath = Join-Path $root "manifest.json"

$RequiredAssets = @(
    @{ id = "license"; path = "LICENSE/LICENSE.md"; version = "1.0.0"; required = $true },
    @{ id = "privacy"; path = "privacy/PRIVACY.md"; version = "1.0.0"; required = $true },
    @{ id = "terms"; path = "terms/TERMS.md"; version = "1.0.0"; required = $true },
    @{ id = "donate"; path = "donate/info.json"; version = "1.0.0"; required = $false }
)

$PrimaryQuoteCandidates = @(
    "quotes/English.json",
    "quotes/english.json"
)

function Write-Step {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
}

function Get-LocalFileSha256 {
    param([string]$RelativePath)

    $file = Join-Path $root ($RelativePath -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path $file)) {
        throw "Missing asset file: $RelativePath"
    }

    return (Get-FileHash -Algorithm SHA256 -Path $file).Hash.ToLower()
}

function Get-RemoteFileSha256 {
    param([string]$RelativePath)

    $encodedPath = ($RelativePath -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    $url = "$RemoteBaseUrl/$encodedPath"
    $tmp = New-TemporaryFile

    try {
        Invoke-WebRequest -Uri $url -OutFile $tmp.FullName -UseBasicParsing | Out-Null
        return (Get-FileHash -Algorithm SHA256 -Path $tmp.FullName).Hash.ToLower()
    }
    finally {
        Remove-Item $tmp.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Get-FileSha256 {
    param([string]$RelativePath)

    if ($RemoteAsSource) {
        return Get-RemoteFileSha256 $RelativePath
    }

    return Get-LocalFileSha256 $RelativePath
}

function Test-ValidJsonFile {
    param([string]$RelativePath)

    $file = Join-Path $root ($RelativePath -replace '/', [IO.Path]::DirectorySeparatorChar)
    $raw = [System.IO.File]::ReadAllText($file)

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Quote file is empty: $RelativePath"
    }

    try {
        $null = $raw | ConvertFrom-Json
    }
    catch {
        throw "Invalid JSON in $RelativePath`: $($_.Exception.Message)"
    }
}

function Resolve-PrimaryQuotePath {
    param([string[]]$QuoteFiles)

    foreach ($candidate in $PrimaryQuoteCandidates) {
        if ($QuoteFiles -contains $candidate) {
            return $candidate
        }
    }

    return $QuoteFiles[0]
}

function Read-ExistingQuotesVersion {
    if (-not (Test-Path $manifestPath)) {
        return "1.1.0"
    }

    try {
        $existing = Get-Content $manifestPath -Raw | ConvertFrom-Json
        $quotes = $existing.assets | Where-Object { $_.id -eq "quotes" } | Select-Object -First 1
        if ($quotes -and $quotes.version) {
            return [string]$quotes.version
        }
    }
    catch {
        Write-Step "Warning: could not read existing manifest.json; using default quotes version 1.1.0" "Yellow"
    }

    return "1.1.0"
}

function Read-ExistingQuoteHashes {
    if (-not (Test-Path $manifestPath)) {
        return @{}
    }

    try {
        $existing = Get-Content $manifestPath -Raw | ConvertFrom-Json
        $quotes = $existing.assets | Where-Object { $_.id -eq "quotes" } | Select-Object -First 1
        if (-not $quotes -or -not $quotes.files) {
            return @{}
        }

        $map = @{}
        foreach ($file in $quotes.files) {
            $map[$file.path] = [string]$file.sha256
        }
        return $map
    }
    catch {
        return @{}
    }
}

function Bump-PatchVersion {
    param([string]$Version)

    if ($Version -match '^(\d+)\.(\d+)\.(\d+)$') {
        $patch = [int]$Matches[3] + 1
        return "$($Matches[1]).$($Matches[2]).$patch"
    }

    return "$Version.1"
}

function Resolve-QuotesVersion {
    param(
        [hashtable]$NewQuoteHashes,
        [hashtable]$OldQuoteHashes,
        [string]$RequestedVersion
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedVersion)) {
        return $RequestedVersion
    }

    $baseVersion = Read-ExistingQuotesVersion

    if ($RemoteAsSource) {
        return $baseVersion
    }

    if ($OldQuoteHashes.Count -eq 0) {
        return $baseVersion
    }

    $changed = $false
    foreach ($path in $NewQuoteHashes.Keys) {
        if (-not $OldQuoteHashes.ContainsKey($path) -or $OldQuoteHashes[$path] -ne $NewQuoteHashes[$path]) {
            $changed = $true
            break
        }
    }

    if (-not $changed) {
        foreach ($path in $OldQuoteHashes.Keys) {
            if (-not $NewQuoteHashes.ContainsKey($path)) {
                $changed = $true
                break
            }
        }
    }

    if ($changed) {
        return Bump-PatchVersion $baseVersion
    }

    return $baseVersion
}

function Write-ManifestFile {
    param(
        [System.Collections.Specialized.OrderedDictionary]$Manifest,
        [string]$Path
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add("{")
    [void]$lines.Add(('  "manifest_version": "{0}",' -f $Manifest.manifest_version))
    [void]$lines.Add('  "assets": [')

    for ($i = 0; $i -lt $Manifest.assets.Count; $i++) {
        $asset = $Manifest.assets[$i]
        $assetComma = if ($i -lt ($Manifest.assets.Count - 1)) { "," } else { "" }

        [void]$lines.Add("    {")
        [void]$lines.Add(('      "id": "{0}",' -f $asset.id))
        [void]$lines.Add(('      "version": "{0}",' -f $asset.version))
        [void]$lines.Add(('      "path": "{0}",' -f $asset.path))
        [void]$lines.Add(('      "sha256": "{0}",' -f $asset.sha256))

        if ($asset.files) {
            [void]$lines.Add(('      "required": {0},' -f ($(if ($asset.required) { "true" } else { "false" }))))
            [void]$lines.Add('      "files": [')

            for ($j = 0; $j -lt $asset.files.Count; $j++) {
                $file = $asset.files[$j]
                $fileComma = if ($j -lt ($asset.files.Count - 1)) { "," } else { "" }
                [void]$lines.Add("        {")
                [void]$lines.Add(('          "path": "{0}",' -f $file.path))
                [void]$lines.Add(('          "sha256": "{0}"' -f $file.sha256))
                [void]$lines.Add("        }$fileComma")
            }

            [void]$lines.Add("      ]")
        }
        else {
            [void]$lines.Add(('      "required": {0}' -f ($(if ($asset.required) { "true" } else { "false" }))))
        }

        [void]$lines.Add("    }$assetComma")
    }

    [void]$lines.Add("  ]")
    [void]$lines.Add("}")

    [System.IO.File]::WriteAllText($Path, ($lines -join [Environment]::NewLine) + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

function New-SingleAssetEntry {
    param(
        [string]$Id,
        [string]$Path,
        [string]$Version,
        [bool]$Required
    )

    return [ordered]@{
        id       = $Id
        version  = $Version
        path     = $Path
        sha256   = (Get-FileSha256 $Path)
        required = $Required
    }
}

function Get-QuotePackage {
    $quoteDir = Join-Path $root "quotes"
    if (-not (Test-Path $quoteDir)) {
        throw "Missing quotes directory: quotes/"
    }

    $legacyQuote = Join-Path $quoteDir "quotes.json"
    if (Test-Path $legacyQuote) {
        throw "Legacy file quotes/quotes.json is not supported. Use quotes/English.json, quotes/Bangla.json, etc."
    }

    $quoteFiles = Get-ChildItem -Path $quoteDir -Filter "*.json" -File |
        Sort-Object Name |
        ForEach-Object { "quotes/$($_.Name)" }

    if ($quoteFiles.Count -eq 0) {
        throw "No quote JSON files found under quotes/"
    }

    if ($RemoteAsSource) {
        foreach ($relativePath in $quoteFiles) {
            try {
                Get-RemoteFileSha256 $relativePath | Out-Null
            }
            catch {
                throw "Quote file exists locally but is missing on GitHub: $relativePath"
            }
        }
    }
    else {
        foreach ($relativePath in $quoteFiles) {
            Test-ValidJsonFile $relativePath
        }
    }

    $packageFiles = [System.Collections.Generic.List[object]]::new()
    $hashMap = @{}

    foreach ($relativePath in $quoteFiles) {
        $sha = Get-FileSha256 $relativePath
        if ($hashMap.ContainsKey($relativePath)) {
            throw "Duplicate quote path in package: $relativePath"
        }

        $hashMap[$relativePath] = $sha
        $packageFiles.Add([ordered]@{
            path   = $relativePath
            sha256 = $sha
        })
    }

    $primaryPath = Resolve-PrimaryQuotePath -QuoteFiles $quoteFiles
    if (-not $hashMap.ContainsKey($primaryPath)) {
        throw "Primary quote path not found in package: $primaryPath"
    }

    return [ordered]@{
        files        = $packageFiles.ToArray()
        primaryPath  = $primaryPath
        primarySha   = $hashMap[$primaryPath]
        hashMap      = $hashMap
    }
}

function Test-RemoteMatchesManifest {
    param($Assets)

    $mismatches = @()

    foreach ($asset in $Assets) {
        if ($asset.files) {
            foreach ($file in $asset.files) {
                try {
                    $remoteSha = Get-RemoteFileSha256 $file.path
                    if ($remoteSha -ne $file.sha256) {
                        $mismatches += [ordered]@{
                            path   = $file.path
                            local  = $file.sha256
                            remote = $remoteSha
                        }
                    }
                }
                catch {
                    $mismatches += [ordered]@{
                        path   = $file.path
                        local  = $file.sha256
                        remote = "MISSING ON GITHUB"
                    }
                }
            }
            continue
        }

        try {
            $remoteSha = Get-RemoteFileSha256 $asset.path
            if ($remoteSha -ne $asset.sha256) {
                $mismatches += [ordered]@{
                    path   = $asset.path
                    local  = $asset.sha256
                    remote = $remoteSha
                }
            }
        }
        catch {
            $mismatches += [ordered]@{
                path   = $asset.path
                local  = $asset.sha256
                remote = "MISSING ON GITHUB"
            }
        }
    }

    return $mismatches
}

Write-Host ""
Write-Step "=== Nayona Assets Manifest Generator ===" "Cyan"
Write-Step "Root: $root"
if ($RemoteAsSource) {
    Write-Step "Source: GitHub ($RemoteBaseUrl)" "Yellow"
}
else {
    Write-Step "Source: local files"
}
Write-Host ""

foreach ($asset in $RequiredAssets) {
    if (-not $RemoteAsSource) {
        $localPath = Join-Path $root ($asset.path -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path $localPath)) {
            throw "Missing required asset file: $($asset.path)"
        }
    }
}

$quotePackage = Get-QuotePackage
$resolvedQuotesVersion = Resolve-QuotesVersion `
    -NewQuoteHashes $quotePackage.hashMap `
    -OldQuoteHashes (Read-ExistingQuoteHashes) `
    -RequestedVersion $QuotesVersion

$assets = [System.Collections.Generic.List[object]]::new()
foreach ($asset in $RequiredAssets) {
    if ($asset.id -eq "donate") {
        continue
    }

    $assets.Add((New-SingleAssetEntry -Id $asset.id -Path $asset.path -Version $asset.version -Required $asset.required))
}

$assets.Add([ordered]@{
    id       = "quotes"
    version  = $resolvedQuotesVersion
    path     = $quotePackage.primaryPath
    sha256   = $quotePackage.primarySha
    required = $true
    files    = $quotePackage.files
})

$donate = $RequiredAssets | Where-Object { $_.id -eq "donate" } | Select-Object -First 1
$assets.Add((New-SingleAssetEntry -Id $donate.id -Path $donate.path -Version $donate.version -Required $donate.required))

$manifest = [ordered]@{
    manifest_version = $ManifestVersion
    assets           = $assets.ToArray()
}

Write-ManifestFile -Manifest $manifest -Path $manifestPath

Write-Step "Wrote $manifestPath" "Green"
Write-Host ""
Write-Step "All assets:"
foreach ($asset in $assets) {
    if ($asset.files) {
        Write-Step ("  quotes v{0} ({1} files, primary: {2})" -f $asset.version, $asset.files.Count, $asset.path) "White"
        foreach ($file in $asset.files) {
            Write-Host ("    {0,-24} {1}" -f $file.path, $file.sha256)
        }
        continue
    }

    Write-Host ("  {0,-8} {1,-24} {2}" -f $asset.id, $asset.path, $asset.sha256)
}
Write-Host ""

if ($VerifyRemote -and -not $RemoteAsSource) {
    Write-Step "Checking local files against GitHub..." "Yellow"
    $mismatches = Test-RemoteMatchesManifest -Assets $assets

    if ($mismatches.Count -eq 0) {
        Write-Step "Remote check passed: safe to push manifest.json." "Green"
    }
    else {
        Write-Step "Remote check failed: local files do NOT match GitHub yet." "Red"
        foreach ($item in $mismatches) {
            Write-Host ""
            Write-Host "  $($item.path)"
            Write-Host "    local : $($item.local)"
            Write-Host "    remote: $($item.remote)"
        }
        Write-Host ""
        Write-Step "Push changed asset files together with manifest.json." "Yellow"
        Write-Step "If you only push manifest.json, Nayona install will fail with checksum mismatch." "Yellow"

        if ($FailOnRemoteMismatch) {
            exit 1
        }
    }
}

if ($RemoteAsSource) {
    Write-Step "Generated manifest from GitHub content." "Green"
    Write-Step "You can push manifest.json only if asset files on GitHub are already correct." "Yellow"
}
else {
    Write-Step "Next step:" "Cyan"
    Write-Step "  1. .\generate-manifest.ps1 -VerifyRemote"
    Write-Step "  2. .\push.ps1"
}

Write-Host ""
