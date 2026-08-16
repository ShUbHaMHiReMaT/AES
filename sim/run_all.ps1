<#
    run_all.ps1 -- full front-end regression for the AES-128 project.

    1. Golden-model known-answer tests (independent Python AES)
    2. S-box cross-check: RTL table vs. algebraic definition
    3. Test-vector generation
    4. Elaboration + simulation of all three cores
    5. Mutation testing: proves the testbenches detect broken RTL

    Usage:
        .\sim\run_all.ps1                 # full regression
        .\sim\run_all.ps1 -Vectors 200    # fewer random vectors, faster
        .\sim\run_all.ps1 -SkipMutation
        .\sim\run_all.ps1 -Vcd            # also dump waveforms to sim/*.vcd
#>

param(
    [int]    $Vectors      = 1000,
    [switch] $SkipMutation,
    [switch] $Vcd
)

# Deliberately not "Stop": in Windows PowerShell 5.1 a native tool writing to
# stderr (iverilog's warnings) raises NativeCommandError and would abort the
# run. Failures are tracked explicitly via $LASTEXITCODE below.
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# scoop-installed iverilog may not be on PATH in a fresh shell
$shims = Join-Path $env:USERPROFILE "scoop\shims"
if (Test-Path $shims) { $env:Path = "$shims;$env:Path" }

if (-not (Get-Command iverilog -ErrorAction SilentlyContinue)) {
    Write-Host "iverilog not found. Install with:  scoop install main/iverilog" -ForegroundColor Red
    exit 1
}

$shared = @("rtl/aes_sbox.v", "rtl/aes_round.v", "rtl/aes_key_expand.v")
$cores  = @(
    @{ Name = "iterative"; Tb = "tb/tb_aes128_iterative.v";      Rtl = "rtl/aes128_iterative.v" },
    @{ Name = "ii10";      Tb = "tb/tb_aes128_iterative_ii10.v"; Rtl = "rtl/aes128_iterative_ii10.v" },
    @{ Name = "pipelined"; Tb = "tb/tb_aes128_pipelined.v";      Rtl = "rtl/aes128_pipelined.v" }
)

$failed = @()

function Step($title) {
    Write-Host ""
    Write-Host ("#" * 62) -ForegroundColor Cyan
    Write-Host "# $title" -ForegroundColor Cyan
    Write-Host ("#" * 62) -ForegroundColor Cyan
}

#------------------------------------------------------------------------------
Step "1-3. Golden model, S-box cross-check, vector generation"
python model/aes_golden.py --check-sbox rtl/aes_sbox.v `
                           --gen-vectors tb/vectors/aes128_vectors.txt -n $Vectors
if ($LASTEXITCODE -ne 0) { $failed += "golden-model" }

#------------------------------------------------------------------------------
Step "4. RTL simulation"
foreach ($c in $cores) {
    $vvp = "sim/$($c.Name).vvp"
    $srcs = @($c.Tb) + $shared + @($c.Rtl)

    & iverilog -g2012 -Wall -o $vvp @srcs
    if ($LASTEXITCODE -ne 0) {
        $failed += "$($c.Name)-compile"
        continue
    }

    if ($Vcd) { & vvp $vvp +dumpvcd } else { & vvp $vvp }
    if ($LASTEXITCODE -ne 0) { $failed += "$($c.Name)-sim" }
}

#------------------------------------------------------------------------------
if (-not $SkipMutation) {
    Step "5. Mutation testing"
    python sim/mutation_test.py
    if ($LASTEXITCODE -ne 0) { $failed += "mutation" }
}

#------------------------------------------------------------------------------
Write-Host ""
Write-Host ("=" * 62)
if ($failed.Count -eq 0) {
    Write-Host " REGRESSION PASSED" -ForegroundColor Green
    Write-Host ("=" * 62)
    exit 0
} else {
    Write-Host " REGRESSION FAILED: $($failed -join ', ')" -ForegroundColor Red
    Write-Host ("=" * 62)
    exit 1
}
