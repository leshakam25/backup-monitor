<#
.SYNOPSIS
  Бекап одного задания: снимок VSS -> архив 7-Zip во временную папку -> проверка -> копия на NAS ->
  ротация старых копий -> отчёт на сервер мониторинга.

.DESCRIPTION
  Обычно задание описано в jobs.psd1, а этот скрипт запускает Планировщик (задачи создаёт
  Install-Agent.ps1 -Apply):
      Backup-Job.ps1 -Job "1C_Buh"
  Параметры командной строки важнее jobs.psd1 — так можно запустить и задание, которого в файле нет:
      Backup-Job.ps1 -Job "test" -Source "D:\Docs" -Destination "\\nas\backup\test" -IntervalHours 24

  Задания на машине выполняются строго по одному (общая очередь).
  Коды выхода: 0 — успешно, 1 — с предупреждениями, 2 — ошибка.
#>
[CmdletBinding()]
param(
    # Имя задания (ключ в jobs.psd1; так же оно видно в боте).
    [Parameter(Mandatory = $true)][string]$Job,
    # Ниже — необязательные переопределения настроек из jobs.psd1 / agent.config.psd1.
    [string[]]$Source,
    [string]$Destination,
    [double]$IntervalHours,
    [int]$KeepDays,
    [int]$MinKeep,
    [string[]]$Exclude,
    [string]$Password,
    [ValidateSet('7z', 'zip')][string]$Format,
    [ValidateRange(0, 9)][int]$Level,
    # Не проверять архив после создания (7z t).
    [switch]$NoTest,
    # Не делать снимок VSS.
    [switch]$NoVss,
    # Путь к файлу настроек агента (по умолчанию agent.config.psd1 рядом со скриптом).
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BackupAgent.Common.ps1')

function Split-List([string[]]$Items) {
    # При запуске через "powershell -File" список "a","b" приходит одной строкой "a,b" — разделяем.
    # Путь, который реально существует с запятой в имени, не трогаем.
    return @($Items | ForEach-Object {
        if ($_ -like '*,*' -and -not (Test-Path -Path $_)) { $_ -split ',' } else { $_ }
    } | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
}

# Обратные слэши в конце удваиваем: иначе "D:\" превращается в \" (экранированную кавычку)
# и склеивает аргументы 7z. Внутренние слэши правила разбора командной строки не трогают.
function Quote([string]$s) { '"' + ($s -replace '(\\+)$', '$1$1') + '"' }

function Resolve-JobSettings {
    # Итоговые настройки: agent.config.psd1 -> jobs.psd1 -> параметры командной строки.
    param($Cfg, [hashtable]$Bound)
    $def = (Get-AgentJobs $Cfg)[$Job]
    if ($def) {
        $errors = @(Test-JobDefinition $Job $def)
        if ($errors.Count) { throw "Задание «$Job» в $($Cfg.JobsFile): $($errors -join '; ')" }
    } elseif (-not $Bound.ContainsKey('Source')) {
        throw "Задание «$Job» не найдено в $($Cfg.JobsFile)"
    }
    $s = @{
        Sources = @(); Destination = $null; IntervalHours = 24.0; Exclude = @(); Password = $null
        KeepDays = [int]$Cfg.KeepDays; MinKeep = [int]$Cfg.MinKeep; Format = $Cfg.Format; Level = [int]$Cfg.Level
        UseVss = [bool]$Cfg.UseVss; Test = $true
    }
    if ($def) {
        $s.Sources = @(@($def.Sources) + @($def.Source) | Where-Object { $_ })
        foreach ($k in 'Destination', 'KeepDays', 'MinKeep', 'Format', 'Level', 'UseVss', 'Test') {
            if ($null -ne $def[$k]) { $s[$k] = $def[$k] }
        }
        if ($def.Exclude) { $s.Exclude = @($def.Exclude) }
        if ($def.Password) { $s.Password = Unprotect-Secret $def.Password }
        $s.IntervalHours = (ConvertFrom-Schedule $def.Schedule).IntervalHours
    }
    if ($Bound.ContainsKey('Source')) { $s.Sources = Split-List $Source }
    if ($Bound.ContainsKey('Exclude')) { $s.Exclude = Split-List $Exclude }
    foreach ($k in 'Destination', 'IntervalHours', 'KeepDays', 'MinKeep', 'Password', 'Format', 'Level') {
        if ($Bound.ContainsKey($k)) { $s[$k] = $Bound[$k] }
    }
    if ($NoTest) { $s.Test = $false }
    if ($NoVss) { $s.UseVss = $false }
    $s.SafeJob = ($Job -replace '[\\/:*?"<>|\s]+', '_')
    if (-not $s.Destination) {
        if (-not $Cfg.NasRoot) { throw 'Не задано место назначения: Destination в задании или NasRoot в agent.config.psd1' }
        $s.Destination = Join-Path $Cfg.NasRoot $s.SafeJob
    }
    if ($s.Password -and $s.Password.Contains('"')) { throw 'Пароль архива не должен содержать двойные кавычки (")' }
    return $s
}

function Invoke-SevenZip {
    # Запускает 7z, весь вывод пишет в лог-файл (UTF-8). Возвращает код выхода.
    param([string]$Exe, [string]$Arguments, [string]$LogFile)
    $errFile = "$LogFile.stderr"
    $p = Start-Process -FilePath $Exe -ArgumentList $Arguments -NoNewWindow -PassThru `
        -RedirectStandardOutput $LogFile -RedirectStandardError $errFile
    $null = $p.Handle          # без этого в PS 5.1 ExitCode иногда пустой
    $p.WaitForExit()
    if ((Test-Path -LiteralPath $errFile) -and (Get-Item -LiteralPath $errFile).Length -gt 0) {
        [IO.File]::AppendAllText($LogFile, [IO.File]::ReadAllText($errFile, [Text.Encoding]::UTF8), [Text.Encoding]::UTF8)
    }
    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    return [int]$p.ExitCode
}

function New-SourceSnapshots {
    # Снимки томов, на которых лежат источники. Ошибка снимка не останавливает бекап (архив без снимка + ⚠️).
    param($Cfg, [string[]]$Paths)
    $res = @{ Snapshots = @{}; Notes = @(); Failed = $false }
    # Сетевые источники снимком не покрыть (VSS — только для локальных томов); это штатно, не ⚠️
    $nonLocal = @($Paths | Where-Object { -not (Get-VolumeRoot $_) })
    if ($nonLocal.Count) { Write-AgentLog "Без снимка (сетевой путь): $($nonLocal -join ', ')" }
    foreach ($v in @($Paths | ForEach-Object { Get-VolumeRoot $_ } | Where-Object { $_ } | Sort-Object -Unique)) {
        try {
            $res.Snapshots[$v] = New-VssSnapshot -Cfg $Cfg -Volume $v
            Write-AgentLog "Снимок VSS тома $v создан"
        } catch {
            $res.Notes += "VSS: $($_.Exception.Message) — архив сделан без снимка, открытые файлы могут быть несогласованы"
            $res.Failed = $true
        }
    }
    return $res
}

function Remove-Snapshots {
    param($Cfg, [hashtable]$Snapshots)
    $allRemoved = $true
    foreach ($s in $Snapshots.Values) {
        try { Remove-VssSnapshot -Cfg $Cfg -Snapshot $s }
        catch { $allRemoved = $false; Write-AgentLog "Не удалось удалить снимок $($s.Id): $($_.Exception.Message)" }
    }
    # если что-то не удалилось — оставляем запись, следующий запуск дочистит
    if ($allRemoved) { Clear-VssState $Cfg }
}

function Copy-ToDestination {
    # Копия через временное имя .partial: на NAS никогда не лежит недокопированный архив под «нормальным» именем.
    param([string]$File, [string]$DestDir)
    if (-not (Test-Path -LiteralPath $DestDir)) { New-Item -ItemType Directory -Path $DestDir -Force | Out-Null }
    $final = Join-Path $DestDir (Split-Path -Leaf $File)
    $partial = "$final.partial"
    Copy-Item -LiteralPath $File -Destination $partial -Force
    $srcLen = (Get-Item -LiteralPath $File).Length
    $dstLen = (Get-Item -LiteralPath $partial).Length
    if ($srcLen -ne $dstLen) {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        throw "копия в $DestDir повреждена: $dstLen байт вместо $srcLen"
    }
    if (Test-Path -LiteralPath $final) { Remove-Item -LiteralPath $final -Force }
    Move-Item -LiteralPath $partial -Destination $final
    return $final
}

function Invoke-Rotation {
    # Удаляет архивы задания старше KeepDays, оставляя минимум MinKeep последних. Возвращает заметки об ошибках.
    param($Set)
    $notes = @()
    if ($Set.KeepDays -le 0) { return $notes }
    $re = '^' + [regex]::Escape($Set.SafeJob) + '_\d{4}-\d{2}-\d{2}_\d{4}\.' + [regex]::Escape($Set.Format) + '$'
    $old = @(Get-ChildItem -LiteralPath $Set.Destination -File | Where-Object { $_.Name -match $re } |
        Sort-Object LastWriteTime -Descending)
    $border = (Get-Date).AddDays(-$Set.KeepDays)
    foreach ($f in @($old | Select-Object -Skip $Set.MinKeep | Where-Object { $_.LastWriteTime -lt $border })) {
        try { Remove-Item -LiteralPath $f.FullName -Force; Write-AgentLog "Удалён старый архив: $($f.Name)" }
        catch { $notes += "Не удалось удалить старый архив $($f.Name): $($_.Exception.Message)" }
    }
    return $notes
}

function Get-SevenZipArgs {
    param($Set, [string]$Archive, [string[]]$Sources, [string]$PwArg)
    $a = @('a', "-t$($Set.Format)", (Quote $Archive))
    $a += @($Sources | ForEach-Object { Quote $_ })
    $a += @("-mx=$($Set.Level)", '-ssw', '-bsp0', '-bse1', '-sccUTF-8', '-y')
    foreach ($x in $Set.Exclude) { $a += (Quote "-xr!$x") }
    if ($PwArg) {
        $a += $PwArg
        if ($Set.Format -eq '7z') { $a += '-mhe=on' }
    }
    return ($a -join ' ')
}

# ======================================================================
$started = Get-Date
$report = [ordered]@{
    run_id         = [guid]::NewGuid().ToString()
    job            = $Job
    host           = $null
    status         = 'error'
    exit_code      = $null
    started        = Get-IsoNow
    finished       = $null
    duration_sec   = $null
    size_bytes     = $null
    files          = $null
    free_bytes     = $null
    archive        = $null
    interval_hours = 24
    method         = $null
    message        = $null
}
$cfg = $null; $set = $null; $lock = $null; $staged = $null
$snap = @{}; $notes = @(); $output = $null; $code = $null

try {
    $cfg = Get-AgentConfig -Path $ConfigPath
    $report.host = $cfg.HostName
    Write-AgentLog "=== Старт задания $Job ==="
    $set = Resolve-JobSettings $cfg $PSBoundParameters
    $report.interval_hours = $set.IntervalHours
    if (-not (Test-Path -LiteralPath $cfg.SevenZip)) { throw "Не найден 7-Zip: $($cfg.SevenZip)" }

    $lock = Enter-AgentLock -TimeoutMinutes $cfg.LockTimeoutMinutes
    if (-not $lock) { throw "Не дождались очереди: другое задание выполняется дольше $($cfg.LockTimeoutMinutes) мин" }
    Clear-StaleVss $cfg

    # Источники: отсутствующие считаем проблемой (иначе 7z молча сделает неполный архив)
    $missing = @($set.Sources | Where-Object { -not (Test-Path -Path $_) })
    $hint = ''
    if (@($missing | Where-Object { Get-UncHost $_ }).Count) { $hint = Get-AccessHint (@($missing | Where-Object { Get-UncHost $_ })[0]) }
    if ($missing.Count -eq $set.Sources.Count) { throw "Не найден ни один источник: $($set.Sources -join ', ')$hint" }
    if ($missing.Count -gt 0) { $notes += "Не найдены источники: $($missing -join ', ')$hint" }
    $present = @($set.Sources | Where-Object { $missing -notcontains $_ })

    $vssFailed = $false
    if ($set.UseVss) {
        $vss = New-SourceSnapshots $cfg $present
        $snap = $vss.Snapshots; $notes += $vss.Notes; $vssFailed = $vss.Failed
        if ($snap.Count -gt 0) { $report.method = 'vss' }
    }
    $archSources = @($present | ForEach-Object { Convert-ToSnapshotPath $_ $snap })

    # ---------- архив во временную папку ----------
    Get-ChildItem -LiteralPath $cfg.StagingDir -Filter "$($set.SafeJob)_*" -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue   # остатки прошлых аварийных запусков
    $staged = Join-Path $cfg.StagingDir ("{0}_{1}.{2}" -f $set.SafeJob, (Get-Date -Format 'yyyy-MM-dd_HHmm'), $set.Format)
    $logFile = Join-Path (Join-Path $cfg.WorkDir 'logs') ("{0}_{1}.log" -f $set.SafeJob, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $pwArg = $null
    if ($set.Password) { $pwArg = Quote "-p$($set.Password)" }

    Write-AgentLog "7z: $staged"
    $code = Invoke-SevenZip -Exe $cfg.SevenZip -Arguments (Get-SevenZipArgs $set $staged $archSources $pwArg) -LogFile $logFile
    $output = Read-TextFile -Path $logFile
    $report.exit_code = $code
    $status = Get-StatusFromExitCode $code
    if ($output -match 'Files read from disk:\s*(\d+)') { $report.files = [int]$Matches[1] }
    elseif ($output -match '(\d+)\s+files') { $report.files = [int]$Matches[1] }

    if (Test-Path -LiteralPath $staged) { $report.size_bytes = (Get-Item -LiteralPath $staged).Length }
    elseif ($status -ne 'error') { $status = 'error'; $notes += 'Архив не создан' }

    if ($set.Test -and $status -ne 'error') {
        $testArgs = @('t', (Quote $staged), '-bsp0', '-bse1', '-sccUTF-8')
        if ($pwArg) { $testArgs += $pwArg }
        $testCode = Invoke-SevenZip -Exe $cfg.SevenZip -Arguments ($testArgs -join ' ') -LogFile "$logFile.test"
        if ($testCode -ne 0) {
            $status = 'error'
            $notes += "Проверка архива не пройдена (7z t, код $testCode)"
            $output += "`n--- 7z t ---`n" + (Read-TextFile -Path "$logFile.test")
        }
        Remove-Item -LiteralPath "$logFile.test" -Force -ErrorAction SilentlyContinue
    }

    # снимок больше не нужен — освобождаем до долгого копирования по сети
    Remove-Snapshots $cfg $snap
    $snap = @{}

    # ---------- копия на NAS и ротация ----------
    if ($status -ne 'error') {
        try { $report.archive = Copy-ToDestination $staged $set.Destination }
        catch { throw "Не удалось скопировать в $($set.Destination): $($_.Exception.Message)$(Get-AccessHint $set.Destination)" }
        Write-AgentLog "Скопировано: $($report.archive)"
        $notes += Invoke-Rotation $set
    }
    if (($missing.Count -gt 0 -or $vssFailed) -and $status -eq 'ok') { $status = 'warning' }

    $report.status = $status
    if ($status -ne 'ok' -or $notes.Count -gt 0) {
        $digest = $null
        if ($code -ne 0 -or $status -eq 'error') { $digest = Get-ErrorDigest -Text $output }
        $report.message = ((@($notes) + @($digest)) | Where-Object { $_ }) -join "`n"
    }
}
catch {
    $report.status = 'error'
    $report.message = ((@($notes) + @("Ошибка: $($_.Exception.Message)")) -join "`n")
    Write-AgentLog "ОШИБКА: $($_.Exception.Message)"
}
finally {
    if ($cfg) {
        if ($snap.Count) { Remove-Snapshots $cfg $snap }
        if ($staged -and (Test-Path -LiteralPath $staged)) { Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue }
        if ($set) { $report.free_bytes = Get-FreeBytes -Path $set.Destination }
    }
    Exit-AgentLock $lock   # отчёт отправляем уже вне очереди — не держим другие задания из-за сети
    $report.finished = Get-IsoNow
    $report.duration_sec = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
    if ($cfg) {
        try { $null = Send-Report -Cfg $cfg -Report $report } catch { Write-AgentLog "Сбой отправки: $($_.Exception.Message)" }
        Remove-OldLogs -Cfg $cfg
    }
    Write-AgentLog "=== Готово: $($report.status) ==="
}

switch ($report.status) { 'ok' { exit 0 } 'warning' { exit 1 } default { exit 2 } }
