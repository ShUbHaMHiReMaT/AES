@echo off
REM ===========================================================================
REM run_xsim.bat -- run the same testbenches under the Vivado Simulator
REM
REM   sim\run_xsim.bat                run all three cores
REM   sim\run_xsim.bat ii10           run one core
REM
REM Run from the repository root with Vivado's settings64.bat already sourced
REM (or add Vivado\<ver>\bin to PATH). Everything the testbenches read is
REM relative to the working directory, so do not cd into sim\.
REM ===========================================================================
setlocal enabledelayedexpansion

where xvlog >nul 2>&1
if errorlevel 1 (
    echo xvlog not found. Source Vivado's settings64.bat first.
    exit /b 1
)

if not exist tb\vectors\aes128_vectors.txt (
    echo Generating test vectors...
    python model\aes_golden.py --gen-vectors tb\vectors\aes128_vectors.txt -n 1000
)

set SHARED=rtl\aes_sbox.v rtl\aes_round.v rtl\aes_key_expand.v

if "%~1"=="" (
    set CORES=iterative ii10 pipelined
) else (
    set CORES=%~1
)

set RC=0
for %%C in (%CORES%) do (
    if "%%C"=="iterative"  ( set TB=tb_aes128_iterative       & set RTL=rtl\aes128_iterative.v )
    if "%%C"=="ii10"       ( set TB=tb_aes128_iterative_ii10  & set RTL=rtl\aes128_iterative_ii10.v )
    if "%%C"=="pipelined"  ( set TB=tb_aes128_pipelined       & set RTL=rtl\aes128_pipelined.v )

    echo.
    echo ============================================================
    echo  xsim: %%C
    echo ============================================================

    xvlog --nolog -sv tb\!TB!.v %SHARED% !RTL!
    if errorlevel 1 ( set RC=1 & goto :next )

    xelab --nolog -debug typical -top !TB! -snapshot !TB!_snap
    if errorlevel 1 ( set RC=1 & goto :next )

    xsim --nolog !TB!_snap -runall
    if errorlevel 1 set RC=1

    :next
)

echo.
if %RC%==0 (
    echo xsim regression PASSED
) else (
    echo xsim regression FAILED
)
exit /b %RC%
