@echo off
setlocal enabledelayedexpansion
REM =======================================================
REM Usage:
REM CheckFileAndRun.bat <FilePath> <CommandToRunIfNotEmpty>
REM =======================================================
set "FILE=%~1"
set "REAL_CMD=%~2"
echo ===========================================
echo Checking file: "%FILE%"
echo Command to run if not empty: "%REAL_CMD%"
echo ===========================================
REM ==== Check if file path is provided ====
if "%FILE%"=="" (
   echo [ERROR] No file path provided!
   exit /b 1
)
REM ==== Check if file exists ====
if not exist "%FILE%" (
   echo [INFO] File does NOT exist. Skipping further execution.
   exit /b 0
)
REM ==== Get file size ====
for %%I in ("%FILE%") do set "SIZE=%%~zI"
echo [INFO] File size = !SIZE! bytes
REM ==== If file size > 0, run real command ====
if !SIZE! GTR 0 (
   echo [INFO] File is NOT empty. Running command...
   call "%REAL_CMD%"
) else (
   echo [INFO] File is EMPTY. Skipping command.
)
echo [INFO] Check Completed
endlocal
exit /b 0
