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

REM The per-core work lives in a subroutine: cmd does not allow a goto label
REM inside a parenthesised for-body, and "set X=a & set Y=b" inside one keeps
REM the trailing spaces in X.
set RC=0
for %%C in (%CORES%) do call :run_core %%C

echo.
if %RC%==0 (
    echo xsim regression PASSED
) else (
    echo xsim regression FAILED
)
exit /b %RC%

:run_core
if "%~1"=="iterative" set "TB=tb_aes128_iterative"
if "%~1"=="iterative" set "RTL=rtl\aes128_iterative.v"
if "%~1"=="ii10"      set "TB=tb_aes128_iterative_ii10"
if "%~1"=="ii10"      set "RTL=rtl\aes128_iterative_ii10.v"
if "%~1"=="pipelined" set "TB=tb_aes128_pipelined"
if "%~1"=="pipelined" set "RTL=rtl\aes128_pipelined.v"

echo.
echo ============================================================
echo  xsim: %~1
echo ============================================================

call xvlog --nolog -sv tb\%TB%.v %SHARED% %RTL%
if errorlevel 1 ( set RC=1& exit /b )

call xelab --nolog -debug typical -top %TB% -snapshot %TB%_snap
if errorlevel 1 ( set RC=1& exit /b )

call xsim --nolog %TB%_snap -runall
if errorlevel 1 set RC=1
exit /b
