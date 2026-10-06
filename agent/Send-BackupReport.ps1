<#
.SYNOPSIS
  Отправляет отчёт о бекапе, сделанном ВАШИМ существующим скриптом (bat/cmd/ps1).
  Ничего не архивирует — только сообщает серверу результат.

.EXAMPLE
  Вставьте в конец своего .bat сразу после строки с 7z:

    "C:\Program Files\7-Zip\7z.exe" a "E:\Backup\1c_%DATE%.7z" "D:\1C" > "C:\BackupAgent\data\logs\1c.log" 2>&1
    set RC=%ERRORLEVEL%
    powershell -NoProfile -ExecutionPolicy Bypass -File "C:\BackupAgent\Send-BackupReport.ps1" ^
        -Job "1C_base" -ExitCode %RC% -ArchivePath "E:\Backup" -LogFile "C:\BackupAgent\data\logs\1c.log" -IntervalHours 24

.EXAMPLE
  Проверка связи с сервером:
    .\Send-BackupReport.ps1 -Job "test" -ExitCode 0 -Message "проверка связи"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Job,
    # Код выхода 7-Zip (%ERRORLEVEL%): 0 — ок, 1 — предупреждения, 2+ — ошибка.
    [Parameter(Mandatory = $true)][int]$ExitCode,
    # Файл архива ИЛИ папка с архивами (тогда берётся самый свежий файл в ней).
    [string]$ArchivePath,
    # Лог вашего скрипта — из него в отчёт попадут строки с ошибками.
    [string]$LogFile,
    # Кодировка лога: auto (по умолчанию: UTF-8 или OEM/cp866), oem, utf8, ansi или номер кодовой страницы.
    [string]$LogEncoding = 'auto',
    [double]$IntervalHours = 24,
    # Время начала бекапа (если знаете) — для подсчёта длительности. Формат: 2026-10-06 02:00:00
    [string]$StartedAt,
    # Произвольный текст в отчёт.
    [string]$Message,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BackupAgent.Common.ps1')

$cfg = Get-AgentConfig -Path $ConfigPath
$status = Get-StatusFromExitCode $ExitCode
$notes = @()

$report = [ordered]@{
    run_id         = [guid]::NewGuid().ToString()
    job            = $Job
    host           = $cfg.HostName
    status         = $status
    exit_code      = $ExitCode
    started        = $null
    finished       = Get-IsoNow
    duration_sec   = $null
    size_bytes     = $null
    files          = $null
    free_bytes     = $null
    archive        = $null
    interval_hours = $IntervalHours
    message        = $null
}

if ($StartedAt) {
    try {
        $s = [datetime]::Parse($StartedAt)
        $report.started = $s.ToString('yyyy-MM-ddTHH:mm:sszzz')
        $report.duration_sec = [math]::Round(((Get-Date) - $s).TotalSeconds, 1)
    } catch { $notes += "Не удалось разобрать StartedAt: $StartedAt" }
}

if ($ArchivePath) {
    $file = $null
    if (Test-Path -LiteralPath $ArchivePath -PathType Container) {
        # самый свежий файл в папке, изменённый за последние сутки + интервал
        $border = (Get-Date).AddHours(-[math]::Max($IntervalHours, 24))
        $file = Get-ChildItem -LiteralPath $ArchivePath -File | Where-Object { $_.LastWriteTime -gt $border } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $file) { $notes += "В папке $ArchivePath нет свежих архивов" }
    } elseif (Test-Path -LiteralPath $ArchivePath -PathType Leaf) {
        $file = Get-Item -LiteralPath $ArchivePath
    } else {
        $notes += "Архив не найден: $ArchivePath"
    }
    if ($file) {
        $report.archive = $file.FullName
        $report.size_bytes = $file.Length
        $report.free_bytes = Get-FreeBytes -Path $file.DirectoryName
    } else {
        if ($status -eq 'ok') { $status = 'error' }
        $report.free_bytes = Get-FreeBytes -Path $ArchivePath
    }
}

$logText = $null
if ($LogFile) {
    $logText = Read-TextFile -Path $LogFile -Encoding $LogEncoding
    if ($null -eq $logText) { $notes += "Лог не найден: $LogFile" }
    elseif ($logText -match 'Files read from disk:\s*(\d+)') { $report.files = [int]$Matches[1] }
}

$report.status = $status
$parts = @()
if ($Message) { $parts += $Message }
$parts += $notes
if ($status -ne 'ok' -and $logText) { $parts += (Get-ErrorDigest -Text $logText) }
if ($parts.Count -gt 0) { $report.message = ($parts | Where-Object { $_ }) -join "`n" }

$sent = Send-Report -Cfg $cfg -Report $report
if (-not $sent) { exit 3 }
exit 0
