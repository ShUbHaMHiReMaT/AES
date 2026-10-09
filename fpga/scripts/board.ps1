<#
    board.ps1 -- program the Nexys A7 and verify the AES cores on hardware.

    Usage (from the repository root):
        .\fpga\scripts\board.ps1                  # program + test, 200 vectors/core
        .\fpga\scripts\board.ps1 -Vectors 1000
        .\fpga\scripts\board.ps1 -Build           # rebuild the bitstream first
        .\fpga\scripts\board.ps1 -SkipProgram     # board already programmed
#>

param(
    [int]    $Vectors = 200,
    [switch] $Build,
    [switch] $SkipProgram,
    [string] $Port = ""
)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $root

# Vivado and Python may not be on PATH in an older shell
$vivadoBin = "C:\Users\shrey\OneDrive\Desktop\Vivado\2023.1\bin"
if (-not (Get-Command vivado -ErrorAction SilentlyContinue) -and (Test-Path $vivadoBin)) {
    $env:Path = "$vivadoBin;$env:Path"
}
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + $env:Path

$logs = Join-Path $root "fpga\build\logs"
New-Item -ItemType Directory -Force $logs | Out-Null

function Step($title) {
    Write-Host ""
    Write-Host ("#" * 62) -ForegroundColor Cyan
    Write-Host "# $title" -ForegroundColor Cyan
    Write-Host ("#" * 62) -ForegroundColor Cyan
}

if ($Build -or -not (Test-Path "fpga\build\aes_nexys_a7.bit")) {
    Step "Build bitstream (takes several minutes)"
    & vivado -mode batch -nojournal -log "$logs\build.log" -source fpga/scripts/build.tcl
    if ($LASTEXITCODE -ne 0) { Write-Host "BUILD FAILED -- see $logs\build.log" -ForegroundColor Red; exit 1 }
}

if (-not $SkipProgram) {
    Step "Program the FPGA over JTAG"
    & vivado -mode batch -nojournal -log "$logs\program.log" -source fpga/scripts/program.tcl
    if ($LASTEXITCODE -ne 0) { Write-Host "PROGRAMMING FAILED -- see $logs\program.log" -ForegroundColor Red; exit 1 }
    Start-Sleep -Milliseconds 500     # let the power-on self-test finish
}

Step "Verify on hardware"
$pyArgs = @("fpga/host/aes_board_test.py", "-n", $Vectors)
if ($Port) { $pyArgs += @("--port", $Port) }
& python @pyArgs
exit $LASTEXITCODE
