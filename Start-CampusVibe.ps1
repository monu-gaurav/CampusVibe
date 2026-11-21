$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot 'backend')
if (!(Test-Path '.venv\Scripts\python.exe')) {
  py -3.11 -m venv .venv
  if ($LASTEXITCODE -ne 0) {throw 'Python 3.11 is required.'}
}
$python = '.\.venv\Scripts\python.exe'
& $python -m pip install -r requirements.txt
if ($LASTEXITCODE -ne 0) { throw 'Could not install dependencies.' }
$secretDir = Join-Path $env:LOCALAPPDATA 'CampusVibeDev'
New-Item -ItemType Directory -Force $secretDir | Out-Null
foreach ($key in @('CAMPUSVIBE_JWT_SECRET','MODERATOR_TOKEN')) {
  $path = Join-Path $secretDir $key
  if (!(Test-Path $path)) {
    $value = & $python -c "import secrets; print(secrets.token_urlsafe(48))"
    Set-Content -Path $path -Value $value -Encoding ASCII
  }
  [Environment]::SetEnvironmentVariable($key,(Get-Content $path -Raw).Trim(),'Process')
}
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
if (Test-Path $adb) { & $adb reverse tcp:8000 tcp:8000 }
$env:LOCAL_MAIL = '1'
Write-Host "CampusVibe API: http://127.0.0.1:8000/docs"
Write-Host "Moderator page: http://127.0.0.1:8000/admin"
Write-Host "Moderator token file: $secretDir\MODERATOR_TOKEN"
& $python -m alembic upgrade head
if ($LASTEXITCODE -ne 0) {throw 'Database migration failed.'}
& $python -m uvicorn main:app --host 127.0.0.1 --port 8000
