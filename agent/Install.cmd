@echo off
rem Backup agent installer: double-click. Requests admin rights itself.
rem Usage: Install.cmd            - install / reconfigure
rem        Install.cmd -Apply     - apply jobs.psd1 to Task Scheduler
rem        Install.cmd -List      - list jobs
rem        Install.cmd -Run NAME  - run job now
setlocal
net session >nul 2>&1
if %errorlevel% neq 0 (
    if "%~1"=="" (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    )
    exit /b
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Agent.ps1" %*
echo.
pause
