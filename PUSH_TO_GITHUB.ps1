# Run from the extracted CampusVibe folder AFTER creating an empty GitHub repository.
# Example: .\PUSH_TO_GITHUB.ps1 -RepoUrl "https://github.com/monu-gaurav/CampusVibe.git"
param(
  [Parameter(Mandatory=$true)]
  [ValidatePattern('^https://github\.com/[^/]+/[^/]+(?:\.git)?$')]
  [string]$RepoUrl
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  throw 'Git for Windows is missing. Install Git from https://git-scm.com/downloads/win and run again.'
}
if (-not (Test-Path '.git')) { git init; if ($LASTEXITCODE -ne 0) { throw 'git init failed' } }
git add .
if ($LASTEXITCODE -ne 0) { throw 'git add failed' }
git diff --cached --quiet
if ($LASTEXITCODE -ne 0) {
  git -c user.name='CampusVibe Owner' -c user.email='campusvibe@users.noreply.github.com' commit -m 'Add CampusVibe Android app and backend source'
  if ($LASTEXITCODE -ne 0) { throw 'Commit failed. Configure Git username/email and retry.' }
}
git branch -M main
if ($LASTEXITCODE -ne 0) { throw 'git branch failed' }
git remote get-url origin *> $null
if ($LASTEXITCODE -eq 0) { git remote set-url origin $RepoUrl }
else { git remote add origin $RepoUrl }
if ($LASTEXITCODE -ne 0) { throw 'git remote setup failed' }
git push -u origin main
if ($LASTEXITCODE -ne 0) { throw 'GitHub push failed. Check GitHub login and that the repository exists.' }
Write-Host 'Source pushed to GitHub. This does NOT deploy Render or build a working APK by itself.'
