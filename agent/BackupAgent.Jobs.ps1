# Задания из jobs.psd1: чтение, проверка, расписание -> XML задачи Планировщика, шифрование паролей.

$script:JobKeys = 'Sources', 'Source', 'Destination', 'Schedule', 'KeepDays', 'MinKeep', 'Exclude',
    'Password', 'Format', 'Level', 'UseVss', 'Test', 'Enabled'
$script:DayNames = @{ mon = 'Monday'; tue = 'Tuesday'; wed = 'Wednesday'; thu = 'Thursday'; fri = 'Friday'; sat = 'Saturday'; sun = 'Sunday' }
$script:DayIndex = @{ Monday = 0; Tuesday = 1; Wednesday = 2; Thursday = 3; Friday = 4; Saturday = 5; Sunday = 6 }
$script:TaskFolder = '\BackupAgent\'

function Get-AgentJobs {
    param($Cfg)
    if (-not (Test-Path -LiteralPath $Cfg.JobsFile)) { return @{} }
    return Import-DataFile -Path $Cfg.JobsFile
}

function Test-JobDefinition {
    # Возвращает список ошибок задания (пустой — всё в порядке).
    param([string]$Name, $Job)
    $errors = @()
    if ($Name -notmatch '^[\w.\- ]{1,60}$') { $errors += "имя «$Name»: только буквы, цифры, пробел, точка, дефис, подчёркивание (до 60)" }
    if ($Name.StartsWith('_')) { $errors += "имя «$Name»: имена с _ в начале заняты служебными задачами" }
    if ($Job -isnot [hashtable]) { return $errors + 'описание должно быть @{ ... }' }
    foreach ($k in $Job.Keys) {
        if ($script:JobKeys -notcontains $k) { $errors += "неизвестный параметр $k (опечатка?)" }
    }
    if (-not ($Job.Sources -or $Job.Source)) { $errors += 'не задан Sources' }
    if (-not $Job.Schedule) { $errors += 'не задан Schedule' }
    else {
        try { $null = ConvertFrom-Schedule $Job.Schedule } catch { $errors += $_.Exception.Message }
    }
    if ($Job.Format -and @('7z', 'zip') -notcontains $Job.Format) { $errors += 'Format: 7z или zip' }
    if ($null -ne $Job.Level -and ([int]$Job.Level -lt 0 -or [int]$Job.Level -gt 9)) { $errors += 'Level: от 0 до 9' }
    return $errors
}

function ConvertFrom-Schedule {
    # 'Daily 01:00' | 'Daily 09:00, 13:00' | 'Every 4h' | 'Every 4h from 08:00' | 'Weekly Mon,Thu 02:00'
    # Возвращает @{ Kind; Times; Days; EveryHours; IntervalHours } — IntervalHours (самый длинный
    # промежуток между запусками) уходит серверу, чтобы сторож знал, когда бекап «пропал».
    param([string]$Text)
    $s = $Text.Trim()
    $timeRe = '((?:\d{1,2}:\d{2}[\s,]*)+)'
    $res = @{ Kind = $null; Times = @(); Days = @(); EveryHours = 0 }

    if ($s -match "^(?i)daily\s+$timeRe$") {
        $res.Kind = 'Daily'; $res.Times = @(ConvertTo-TimeList $Matches[1])
        $res.Days = @($script:DayIndex.Keys)
    } elseif ($s -match '^(?i)every\s+(\d{1,2})\s*h(?:\s+from\s+(\d{1,2}:\d{2}))?$') {
        $n = [int]$Matches[1]
        if ($n -lt 1 -or $n -gt 23) { throw "Schedule «$Text»: Every от 1h до 23h (раз в сутки — Daily)" }
        $start = '00:00'
        if ($Matches[2]) { $start = $Matches[2] }
        $res.Kind = 'Every'; $res.EveryHours = $n; $res.Times = @(ConvertTo-TimeList $start)
        $res.Days = @($script:DayIndex.Keys)
    } elseif ($s -match "^(?i)weekly\s+([a-z,\s]+?)\s+$timeRe$") {
        $res.Kind = 'Weekly'; $res.Times = @(ConvertTo-TimeList $Matches[2])
        foreach ($d in ($Matches[1] -split '[,\s]+' | Where-Object { $_ })) {
            $full = $script:DayNames[$d.Substring(0, [Math]::Min(3, $d.Length)).ToLower()]
            if (-not $full) { throw "Schedule «$Text»: непонятный день «$d» (Mon Tue Wed Thu Fri Sat Sun)" }
            if ($res.Days -notcontains $full) { $res.Days += $full }
        }
    } else {
        throw "Schedule «$Text» не распознан. Примеры: 'Daily 01:00', 'Daily 09:00, 18:00', 'Every 4h', 'Weekly Mon,Thu 02:00'"
    }
    $res.IntervalHours = Get-ScheduleIntervalHours $res
    return $res
}

function ConvertTo-TimeList {
    param([string]$Text)
    $list = @()
    foreach ($t in ($Text -split '[,\s]+' | Where-Object { $_ })) {
        $h, $m = $t -split ':'
        if ([int]$h -gt 23 -or [int]$m -gt 59) { throw "неверное время «$t»" }
        $list += New-Object TimeSpan([int]$h, [int]$m, 0)
    }
    return $list | Sort-Object -Unique   # вызывающий оборачивает в @()
}

function Get-ScheduleIntervalHours {
    # Самый длинный промежуток между соседними запусками за неделю (с переходом через воскресенье).
    param($Sched)
    # Повтор (Every) Планировщик выполняет в течение суток от времени старта — и после полуночи тоже.
    $week = 7 * 1440
    $events = @()
    foreach ($day in $Sched.Days) {
        $dayStart = $script:DayIndex[$day] * 1440
        foreach ($t in $Sched.Times) {
            $offset = 0
            do {
                $events += ($dayStart + $t.TotalMinutes + $offset) % $week
                $offset += $Sched.EveryHours * 60
            } while ($Sched.EveryHours -gt 0 -and $offset -lt 1440)
        }
    }
    $events = @($events | Sort-Object -Unique)
    if ($events.Count -eq 1) { return 168.0 }
    $maxGap = $events[0] + 7 * 1440 - $events[-1]
    for ($i = 1; $i -lt $events.Count; $i++) { $maxGap = [Math]::Max($maxGap, $events[$i] - $events[$i - 1]) }
    return [Math]::Round($maxGap / 60.0, 2)
}

function New-ScheduleTriggersXml {
    # Триггеры Планировщика для расписания из jobs.psd1
    param($Sched)
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $triggers = foreach ($t in $Sched.Times) {
        $start = '{0}T{1:hh\:mm}:00' -f $today, $t
        $rep = ''
        if ($Sched.Kind -eq 'Every') {
            $rep = "<Repetition><Interval>PT$($Sched.EveryHours)H</Interval><Duration>P1D</Duration><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>"
        }
        if ($Sched.Kind -eq 'Weekly') {
            $days = ($Sched.Days | ForEach-Object { "<$_ />" }) -join ''
            $by = "<ScheduleByWeek><WeeksInterval>1</WeeksInterval><DaysOfWeek>$days</DaysOfWeek></ScheduleByWeek>"
        } else {
            $by = '<ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>'
        }
        "<CalendarTrigger>$rep<StartBoundary>$start</StartBoundary><Enabled>true</Enabled>$by</CalendarTrigger>"
    }
    return ($triggers -join '')
}

function New-AgentTaskXml {
    # XML задачи Планировщика от SYSTEM (схема 1.2 — понимают Server 2012 R2 и Windows 10/11).
    # Порядок элементов как в экспорте Планировщика: импорт к нему чувствителен.
    param([string]$Description, [string]$ScriptPath, [string]$Arguments, [string]$TriggersXml,
          [bool]$Enabled = $true, [string]$TimeLimit = 'P1D')
    $esc = { param($s) [Security.SecurityElement]::Escape($s) }
    $psExe = '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe'   # 64-бит: нужен для VSS
    $taskArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" {1}' -f $ScriptPath, $Arguments
    $enabledText = 'false'
    if ($Enabled) { $enabledText = 'true' }
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>$(& $esc $Description)</Description></RegistrationInfo>
  <Triggers>$TriggersXml</Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>$enabledText</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>$TimeLimit</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$psExe</Command>
      <Arguments>$(& $esc $taskArgs)</Arguments>
      <WorkingDirectory>$(& $esc (Split-Path -Parent $ScriptPath))</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
}

function New-JobTaskXml {
    param([string]$Name, $Sched, [string]$ScriptPath, [bool]$Enabled = $true)
    return New-AgentTaskXml -Description "Бекап «$Name» — создано из jobs.psd1, правьте jobs.psd1" `
        -ScriptPath $ScriptPath -Arguments ('-Job "{0}"' -f $Name) -TriggersXml (New-ScheduleTriggersXml $Sched) -Enabled $Enabled
}

function Protect-JobsFile {
    # Заменяет пароли, вписанные открытым текстом, на зашифрованные (dpapi:...). Возвращает число замен.
    param([string]$Path)
    $text = Read-TextFile -Path $Path -Fallback 'ansi'
    $script:protectedCount = 0
    $pattern = '(?m)(\bPassword\s*=\s*)(?:''((?:[^'']|'''')*)''|"([^"]*)")'
    $new = [regex]::Replace($text, $pattern, {
        param($m)
        $plain = $m.Groups[2].Value -replace "''", "'"
        if ($m.Groups[3].Success) { $plain = $m.Groups[3].Value }
        if (-not $plain -or $plain.StartsWith('dpapi:')) { return $m.Value }
        $script:protectedCount++
        return $m.Groups[1].Value + "'" + (Protect-Secret $plain) + "'"
    })
    if ($script:protectedCount -gt 0) {
        [IO.File]::WriteAllText($Path, $new, (New-Object Text.UTF8Encoding $true))
    }
    return $script:protectedCount
}
