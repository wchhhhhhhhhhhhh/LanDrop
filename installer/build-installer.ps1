$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$iscc = 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
if (-not (Test-Path $iscc)) {
    Write-Output 'installing Inno Setup...'
    Invoke-WebRequest 'https://jrsoftware.org/download.php/is.exe' -OutFile 'C:\innosetup.exe'
    Start-Process 'C:\innosetup.exe' -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait
}
if (-not (Test-Path $iscc)) { throw 'Inno Setup not found' }

Set-Location 'C:\LanDropInstaller'
& $iscc 'C:\LanDropInstaller\LanDrop.iss'
if ($LASTEXITCODE -ne 0) { throw "ISCC failed: $LASTEXITCODE" }

Get-ChildItem 'C:\LanDropInstaller\dist' | Select-Object Name, Length
