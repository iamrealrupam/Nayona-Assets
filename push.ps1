$Repo = "https://github.com/iamrealrupam/Nayona-Assets.git"

Set-Location $PSScriptRoot

Write-Host ""
Write-Host "=== Nayona-Assets Git Push ===" -ForegroundColor Cyan
Write-Host "Folder: $PSScriptRoot"
Write-Host ""

if (-not (Test-Path ".git")) {
    git init
    git branch -M main
}

# Normalize paths before comparing
$topLevel = (Resolve-Path (git rev-parse --show-toplevel).Trim()).Path
$scriptRoot = (Resolve-Path $PSScriptRoot).Path

if ($topLevel.TrimEnd('\').ToLower() -ne $scriptRoot.TrimEnd('\').ToLower()) {
    Write-Host "ERROR: Git repo root is wrong." -ForegroundColor Red
    Write-Host "  Expected: $scriptRoot"
    Write-Host "  Found   : $topLevel"
    Write-Host ""
    Write-Host "Fix: delete the wrong .git folder, then run this script again from Nayona-Assets only."
    Write-Host "Do NOT run git init inside C:\Users\rupma (home folder)."
    Read-Host "Press Enter to exit"
    exit 1
}

git remote remove origin 2>$null
git remote add origin $Repo

Write-Host ""
Write-Host "Regenerating manifest checksums from local files..." -ForegroundColor Yellow
& "$PSScriptRoot\generate-manifest.ps1" -VerifyRemote

if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
    Write-Host ""
    Write-Host "Remote verify failed. Either:" -ForegroundColor Yellow
    Write-Host "  1) Push asset files first, then run: .\generate-manifest.ps1 -RemoteAsSource"
    Write-Host "  2) Or fix local files to match GitHub, then push everything together."
    $continue = Read-Host "Continue push anyway? (y/N)"
    if ($continue -notin @("y","Y")) {
        exit 1
    }
}

git add manifest.json generate-manifest.ps1 push.ps1 LICENSE privacy terms quotes donate

git diff --cached --quiet

if ($LASTEXITCODE -eq 0) {
    Write-Host "No changes to commit." -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit
}

$msg = Read-Host "Commit message (blank = Update assets and manifest)"

if ([string]::IsNullOrWhiteSpace($msg)) {
    $msg = "Update assets and manifest"
}

git commit -m "$msg"
git pull origin main --rebase 2>$null
git push -u origin main

Write-Host ""
Write-Host "Done! Verify live manifest:" -ForegroundColor Green
Write-Host "  https://raw.githubusercontent.com/iamrealrupam/Nayona-Assets/main/manifest.json"
Write-Host ""

Read-Host "Press Enter to exit"