<#
.SYNOPSIS
  Установка и обслуживание агента бекапов. Запускать от администратора (проще — через Install.cmd).

.EXAMPLE
  Install.cmd                          # установка/перенастройка: файлы, 7-Zip, сервер+токен, NAS, VSS
  Install.cmd -Apply                   # применить jobs.psd1 сейчас (иначе применится сам в течение 10 минут)
  Install.cmd -List                    # задания, последний и следующий запуск
  Install.cmd -Run 1C_Buh              # запустить задание сейчас (от SYSTEM, как Планировщик) и показать лог
  Install.cmd -Credential \\nas\backup # сохранить логин/пароль для сетевого ресурса в Диспетчер учётных данных
  Install.cmd -Credentials             # какие сетевые учётные данные сохранены
  Install.cmd -RemoveCredential nas    # удалить сохранённые учётные данные
#>
[CmdletBinding(DefaultParameterSetName = 'Setup')]
param(
    [Parameter(ParameterSetName = 'Apply')][switch]$Apply,
    [Parameter(ParameterSetName = 'List')][switch]$List,
    [Parameter(ParameterSetName = 'Run')][string]$Run,
    [Parameter(ParameterSetName = 'Credential')][string]$Credential,
    [Parameter(ParameterSetName = 'Credentials')][switch]$Credentials,
    [Parameter(ParameterSetName = 'RemoveCredential')][string]$RemoveCredential,
    # служебные: запускаются Планировщиком от SYSTEM
    [Parameter(ParameterSetName = 'Sync')][switch]$Sync,
    [Parameter(ParameterSetName = 'SystemHelper')][string]$SystemHelper,
    [string]$InstallDir = 'C:\BackupAgent'
)

$ErrorActionPreference = 'Stop'
$AgentFiles = 'Backup-Job.ps1', 'Send-BackupReport.ps1', 'Install-Agent.ps1', 'Install.cmd',
    'BackupAgent.Common.ps1', 'BackupAgent.Vss.ps1', 'BackupAgent.Creds.ps1', 'BackupAgent.Jobs.ps1',
    'agent.config.example.psd1', 'jobs.example.psd1'
$DefaultServer = 'https://backup.example.ru/api/report'   # deploy.ps1 подставляет домен сервера в архив агента
$ConfigJobName = 'jobs.psd1'          # под этим именем в бот приходит результат автоприменения
. (Join-Path $PSScriptRoot 'BackupAgent.Common.ps1')

# ---------- ввод/вывод ----------
function Write-Step([string]$Text) { Write-Host "`n=== $Text ===" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "  [OK] $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "  [!] $Text" -ForegroundColor Yellow }

function Read-Value([string]$Prompt, [string]$Default) {
    $suffix = ''
    if ($Default) { $suffix = " [$Default]" }
    $v = Read-Host "  $Prompt$suffix"
    if (-not $v) { return $Default }
    return $v.Trim()
}

function Read-YesNo([string]$Prompt, [bool]$Default = $true) {
    $hint = '[Д/н]'
    if (-not $Default) { $hint = '[д/Н]' }
    $v = (Read-Host "  $Prompt $hint").Trim().ToLower()
    if (-not $v) { return $Default }
    return @('д', 'да', 'y', 'yes') -contains $v
}

function Read-Secret([string]$Prompt) {
    $sec = Read-Host "  $Prompt" -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function ConvertTo-Psd1String([string]$s) { "'" + ($s -replace "'", "''") + "'" }

# ---------- проверки окружения ----------
function Assert-Environment {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Нужны права администратора: запустите Install.cmd (он сам запросит права).'
    }
    if ($PSVersionTable.PSVersion.Major -lt 4) {
        throw "Нужен PowerShell 4.0+, сейчас $($PSVersionTable.PSVersion). Установите WMF 5.1."
    }
}

function Install-AgentFiles {
    Write-Step "Файлы агента -> $InstallDir"
    $src = (Resolve-Path $PSScriptRoot).ProviderPath.TrimEnd('\')
    if (-not (Test-Path -LiteralPath $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
    $dst = (Resolve-Path $InstallDir).ProviderPath.TrimEnd('\')
    if ($src -ne $dst) {
        foreach ($f in $AgentFiles) { Copy-Item -LiteralPath (Join-Path $src $f) -Destination $dst -Force }
        Write-Ok 'файлы скопированы'
    } else {
        Write-Ok 'запуск из папки установки — копировать нечего'
    }
    $old = Join-Path $dst 'BackupAgent.Nas.ps1'   # модуль версии 2.0, заменён Диспетчером учётных данных
    if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
    Get-ChildItem -LiteralPath $dst -File | Unblock-File
    # В папке токен и пароли архивов: доступ только администраторам и SYSTEM (SID — не зависят от языка Windows)
    $out = & icacls.exe $dst /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' /T /C /Q 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Warn "не удалось ограничить права на папку: $out" } else { Write-Ok 'доступ к папке: только администраторы и SYSTEM' }
}

function Install-SevenZip {
    Write-Step '7-Zip'
    foreach ($p in "$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe") {
        if ($p -and (Test-Path -LiteralPath $p)) { Write-Ok "найден: $p"; return $p }
    }
    if (-not (Read-YesNo '7-Zip не найден. Скачать с 7-zip.org и установить?')) { throw 'Без 7-Zip агент работать не может.' }
    Enable-Tls12
    $page = (Invoke-WebRequest -Uri 'https://www.7-zip.org/download.html' -UseBasicParsing).Content
    $re = 'href="(a/7z\d+\.msi)"'
    if ([Environment]::Is64BitOperatingSystem) { $re = 'href="(a/7z\d+-x64\.msi)"' }
    if ($page -notmatch $re) { throw 'Не нашёл ссылку на MSI на 7-zip.org — установите 7-Zip вручную и запустите установщик снова.' }
    $msi = Join-Path $env:TEMP (Split-Path -Leaf $Matches[1])
    Invoke-WebRequest -Uri ('https://www.7-zip.org/' + $Matches[1]) -OutFile $msi -UseBasicParsing
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
    Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
    if (@(0, 3010) -notcontains $p.ExitCode) { throw "Установка 7-Zip завершилась с кодом $($p.ExitCode)" }
    $exe = "$env:ProgramFiles\7-Zip\7z.exe"
    Write-Ok "установлен: $exe"
    return $exe
}

# ---------- действия от имени SYSTEM ----------
# Задания работают от SYSTEM: и учётные данные нужно класть в хранилище SYSTEM, и доступ проверять от SYSTEM.
# Запрос передаётся файлом, зашифрованным ключом машины, через разовую задачу Планировщика.
function Invoke-AsSystem([hashtable]$Request, $Cfg) {
    $dir = Join-Path $Cfg.WorkDir 'helper'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $req = Join-Path $dir ([guid]::NewGuid().ToString('N') + '.req')
    [IO.File]::WriteAllText($req, (Protect-Secret ($Request | ConvertTo-Json -Compress)))
    $xml = New-AgentTaskXml -Description 'Служебная разовая задача агента бекапов (удаляется сама)' `
        -ScriptPath (Join-Path $InstallDir 'Install-Agent.ps1') `
        -Arguments ('-SystemHelper "{0}" -InstallDir "{1}"' -f $req, $InstallDir) -TriggersXml '' -TimeLimit 'PT5M'
    Register-ScheduledTask -TaskName '_Helper' -TaskPath $script:TaskFolder -Xml $xml -Force | Out-Null
    try {
        Start-ScheduledTask -TaskName '_Helper' -TaskPath $script:TaskFolder
        $deadline = (Get-Date).AddMinutes(2)
        do { Start-Sleep -Milliseconds 500 } while (-not (Test-Path -LiteralPath "$req.out") -and (Get-Date) -lt $deadline)
        if (-not (Test-Path -LiteralPath "$req.out")) { throw 'служебная задача от SYSTEM не ответила за 2 минуты' }
        Start-Sleep -Milliseconds 300   # дать дописать файл
        return ([IO.File]::ReadAllText("$req.out", [Text.Encoding]::UTF8) | ConvertFrom-Json)
    } finally {
        Unregister-ScheduledTask -TaskName '_Helper' -TaskPath $script:TaskFolder -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $req, "$req.out" -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-SystemHelper([string]$RequestPath) {
    # Выполняется от SYSTEM внутри разовой задачи. Отвечает JSON-файлом рядом с запросом.
    $res = @{ ok = $true; message = ''; items = @() }
    try {
        $r = (Unprotect-Secret ([IO.File]::ReadAllText($RequestPath))) | ConvertFrom-Json
        Remove-Item -LiteralPath $RequestPath -Force
        Initialize-CredApi
        switch ($r.action) {
            'add' { [BackupAgent.CredStore]::Write($r.target, $r.user, $r.password) }
            'remove' { $res.ok = [BackupAgent.CredStore]::Delete($r.target) }
            'list' { $res.items = @([BackupAgent.CredStore]::List()) }
        }
        if ($r.path) { $res.message = Test-PathAccess $r.path ([bool]$r.write) }
    } catch { $res.ok = $false; $res.message = $_.Exception.Message }
    [IO.File]::WriteAllText("$RequestPath.out", ($res | ConvertTo-Json -Compress), [Text.Encoding]::UTF8)
}

function Test-PathAccess([string]$Path, [bool]$Write) {
    # Бросает ошибку, если нет доступа. Возвращает короткое описание (свободное место).
    if (-not (Test-Path -LiteralPath $Path)) {
        if (-not $Write) { throw "нет доступа к $Path (или такой папки нет)" }
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    if ($Write) {
        $probe = Join-Path $Path ('.backupagent_probe_' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, 'probe')
        Remove-Item -LiteralPath $probe -Force
    } else {
        $null = Get-ChildItem -LiteralPath $Path | Select-Object -First 1
    }
    $free = Get-FreeBytes $Path
    if ($free -and $Write) { return ('{0:N0} ГБ свободно' -f ($free / 1GB)) }
    return 'доступ есть'
}

# ---------- сетевые учётные данные ----------
function Get-CredentialTarget([string]$Text) {
    $h = Get-UncHost $Text
    if ($h) { return $h }
    return $Text.Trim().TrimStart('\')
}

function Add-SystemCredential($Cfg, [string]$Target, [string]$TestPath, [bool]$Write) {
    # Спрашивает логин/пароль, кладёт в хранилище SYSTEM и проверяет доступ. Возвращает $true при успехе.
    Write-Host "  Логин и пароль для \\$Target сохранятся в Диспетчере учётных данных Windows (хранилище SYSTEM)."
    $user = Read-Value 'Логин (для NAS обычно просто имя; для компьютера в сети — ИМЯ-ПК\пользователь)' $null
    if (-not $user) { return $false }
    $pw = Read-Secret 'Пароль'
    $r = Invoke-AsSystem @{ action = 'add'; target = $Target; user = $user; password = $pw; path = $TestPath; write = $Write } $Cfg
    if ($r.ok) { Write-Ok "сохранено для \\$Target; $($r.message)"; return $true }
    Write-Warn "сохранено, но проверка не прошла: $($r.message)"
    return $false
}

function Invoke-CredentialCommand($Cfg) {
    switch ($PSCmdlet.ParameterSetName) {
        'Credential' {
            Write-Step "Учётные данные для $Credential"
            $path = $null
            if ($Credential -match '^\\\\[^\\]+\\[^\\]+') { $path = $Credential }
            [void](Add-SystemCredential $Cfg (Get-CredentialTarget $Credential) $path $false)
        }
        'Credentials' {
            Write-Step 'Сохранённые сетевые учётные данные (хранилище SYSTEM)'
            $r = Invoke-AsSystem @{ action = 'list' } $Cfg
            if (-not $r.ok) { throw $r.message }
            if (-not @($r.items).Count) { Write-Warn 'нет сохранённых учётных данных' }
            foreach ($i in @($r.items)) { $t, $u = $i -split '\|', 2; Write-Host "  \\$t  ->  $u" }
        }
        'RemoveCredential' {
            $t = Get-CredentialTarget $RemoveCredential
            $r = Invoke-AsSystem @{ action = 'remove'; target = $t } $Cfg
            if ($r.ok) { Write-Ok "удалено: \\$t" } else { Write-Warn "не найдено: \\$t" }
        }
    }
}

# ---------- подключение к серверу ----------
function Test-ServerToken([string]$ServerUrl, [string]$Token) {
    # Возвращает название компании или бросает понятную ошибку.
    Enable-Tls12
    $url = (Get-ServerBase $ServerUrl) + '/api/ping'
    try {
        $r = Invoke-RestMethod -Uri $url -Method Post -Headers @{ 'X-Token' = $Token } -TimeoutSec 20 -UseBasicParsing
        return $r.company
    } catch {
        $code = $null
        try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        if ($code -eq 401) { throw 'сервер не принял токен (проверьте токен компании в боте: Компании -> компания -> Токен)' }
        if ($_.Exception.Message -match 'SSL|TLS|trust|доверия|сертификат') {
            throw "ошибка TLS: $($_.Exception.Message). На давно не обновлявшемся Windows может не быть корневого сертификата Let's Encrypt (ISRG Root X1) — установите обновления корневых сертификатов."
        }
        throw "сервер недоступен: $($_.Exception.Message)"
    }
}

function Read-ServerSettings($Old) {
    Write-Step 'Сервер мониторинга'
    while ($true) {
        $default = $DefaultServer
        if ($Old -and $Old.ServerUrl) { $default = $Old.ServerUrl }
        $url = Read-Value 'Адрес приёма отчётов' $default
        $oldToken = $null
        if ($Old) { $oldToken = $Old.Token }
        $tokenHint = ''
        if ($oldToken) { $tokenHint = '(Enter — оставить текущий)' }
        $token = Read-Value "Токен компании из бота $tokenHint" $null
        if (-not $token) { $token = $oldToken }
        try {
            $company = Test-ServerToken $url $token
            Write-Ok "компания: $company"
            return @{ ServerUrl = $url; Token = $token }
        } catch { Write-Warn $_.Exception.Message }
    }
}

# ---------- NAS ----------
function Read-NasRoot($Cfg, $Old) {
    Write-Step 'NAS (куда складывать бекапы)'
    while ($true) {
        $default = $null
        if ($Old) { $default = $Old.NasRoot }
        $root = Read-Value 'Сетевая папка, например \\192.168.1.10\backup' $default
        if ($root -notmatch '^\\\\[^\\]+\\[^\\]+') { Write-Warn 'нужен сетевой путь вида \\сервер\папка'; continue }
        $root = $root.TrimEnd('\')
        $r = Invoke-AsSystem @{ action = 'check'; path = $root; write = $true } $Cfg
        if ($r.ok) { Write-Ok "запись на NAS от SYSTEM работает: $($r.message)"; return $root }
        Write-Warn "от SYSTEM нет доступа: $($r.message)"
        if ((Read-YesNo 'Сохранить логин и пароль NAS в Диспетчере учётных данных?') -and
            (Add-SystemCredential $Cfg (Get-UncHost $root) $root $true)) { return $root }
    }
}

# ---------- конфиг ----------
function Save-AgentConfig([hashtable]$Values, $Old) {
    $path = Join-Path $InstallDir 'agent.config.psd1'
    $extra = ''
    if ($Old) {
        # Ручные настройки (UseVss, KeepDays, StagingDir...) переносим как есть; устаревшие NasUser/NasPassword — нет
        $skip = 'ServerUrl', 'Token', 'NasRoot', 'NasUser', 'NasPassword', 'SevenZip', 'WorkDir', 'ConfigPath', 'JobsFile'
        foreach ($k in ($Old.Keys | Where-Object { $skip -notcontains $_ } | Sort-Object)) {
            $v = $Old[$k]
            if ($v -is [bool]) { $v = '$' + $v.ToString().ToLower() } elseif ($v -is [string]) { $v = ConvertTo-Psd1String $v }
            $extra += "    $k = $v`r`n"
        }
    }
    $nas = "    NasRoot   = $(ConvertTo-Psd1String $Values.NasRoot)`r`n"
    if (-not $Values.NasRoot) { $nas = '' }
    $text = @"
# Настройки агента бекапов. Создано Install-Agent.ps1 $(Get-Date -Format 'yyyy-MM-dd HH:mm').
# Подробности о параметрах — в agent.config.example.psd1. Пароли сюда не пишутся:
# сетевые — в Диспетчере учётных данных (Install.cmd -Credential), архивов — в jobs.psd1 (шифруются).
@{
    ServerUrl = $(ConvertTo-Psd1String $Values.ServerUrl)
    Token     = $(ConvertTo-Psd1String $Values.Token)
    SevenZip  = $(ConvertTo-Psd1String $Values.SevenZip)
    WorkDir   = $(ConvertTo-Psd1String (Join-Path $InstallDir 'data'))
$nas$extra}
"@
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $true))
    Write-Ok "настройки сохранены: $path"
}

function Test-Vss($Cfg) {
    Write-Step 'Проверка теневых копий (VSS)'
    $vol = $env:SystemDrive + '\'
    try {
        Clear-StaleVss $Cfg
        $s = New-VssSnapshot -Cfg $Cfg -Volume $vol
        $ok = Test-Path -LiteralPath (Join-Path $s.Link 'Windows')
        Remove-VssSnapshot -Cfg $Cfg -Snapshot $s
        Clear-VssState $Cfg
        if ($ok) { Write-Ok "снимок $vol создан, прочитан и удалён" } else { Write-Warn 'снимок создан, но прочитать его не удалось' }
    } catch {
        Write-Warn "VSS не работает: $($_.Exception.Message). Бекапы будут делаться без снимка (открытые файлы — с риском)."
    }
}

# ---------- задания ----------
function Invoke-Apply($Cfg) {
    # Синхронизирует задачи Планировщика с jobs.psd1. Ничего не печатает — возвращает итог.
    $res = @{ Errors = @(); Warnings = @(); Applied = @(); Removed = @(); Protected = 0 }
    if (-not (Test-Path -LiteralPath $Cfg.JobsFile)) { $res.Errors += "нет файла $($Cfg.JobsFile)"; return $res }
    try {
        $res.Protected = Protect-JobsFile $Cfg.JobsFile
        $jobs = Get-AgentJobs $Cfg
    } catch { $res.Errors += $_.Exception.Message; return $res }
    foreach ($name in $jobs.Keys) {
        foreach ($e in @(Test-JobDefinition $name $jobs[$name])) { $res.Errors += "${name}: $e" }
        if (-not $jobs[$name].Destination -and -not $Cfg.NasRoot) { $res.Errors += "${name}: нет Destination и не задан NasRoot" }
    }
    if ($res.Errors.Count) { return $res }   # с ошибками в файле Планировщик не трогаем

    $jobScript = Join-Path $InstallDir 'Backup-Job.ps1'
    foreach ($name in ($jobs.Keys | Sort-Object)) {
        $job = $jobs[$name]
        foreach ($src in @(@($job.Sources) + @($job.Source) | Where-Object { $_ })) {
            if (-not (Test-Path -Path $src)) { $res.Warnings += "${name}: источник не найден: $src" }
        }
        $enabled = $true
        if ($null -ne $job.Enabled) { $enabled = [bool]$job.Enabled }
        $sched = ConvertFrom-Schedule $job.Schedule
        $xml = New-JobTaskXml -Name $name -Sched $sched -ScriptPath $jobScript -Enabled $enabled
        Register-ScheduledTask -TaskName $name -TaskPath $script:TaskFolder -Xml $xml -Force | Out-Null
        $off = ''
        if (-not $enabled) { $off = ' — отключено' }
        $res.Applied += "${name}: $($job.Schedule)$off"
    }
    foreach ($t in @(Get-ScheduledTask -TaskPath $script:TaskFolder -ErrorAction SilentlyContinue)) {
        if ($t.TaskName.StartsWith('_') -or $jobs.ContainsKey($t.TaskName)) { continue }
        Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $script:TaskFolder -Confirm:$false
        $res.Removed += $t.TaskName
    }
    Save-AppliedHash $Cfg
    return $res
}

function Get-JobsHash($Cfg) {
    if (-not (Test-Path -LiteralPath $Cfg.JobsFile)) { return '' }
    return (Get-FileHash -LiteralPath $Cfg.JobsFile -Algorithm SHA256).Hash
}

function Save-AppliedHash($Cfg) {
    [IO.File]::WriteAllText((Join-Path $Cfg.WorkDir 'jobs.applied'), (Get-JobsHash $Cfg))
}

function Show-ApplyResult($Res) {
    Write-Step 'Применение jobs.psd1'
    if ($Res.Protected) { Write-Ok "паролей зашифровано: $($Res.Protected)" }
    foreach ($e in $Res.Errors) { Write-Warn $e }
    if ($Res.Errors.Count) { throw 'В jobs.psd1 есть ошибки — задачи в Планировщике не менялись.' }
    foreach ($a in $Res.Applied) { Write-Ok $a }
    foreach ($r in $Res.Removed) { Write-Ok "${r}: задача удалена (нет в jobs.psd1)" }
    foreach ($w in $Res.Warnings) { Write-Warn $w }
    if (-not $Res.Applied.Count) { Write-Warn 'в jobs.psd1 нет заданий' }
}

function Invoke-Sync($Cfg) {
    # Служебная задача _Sync (раз в 10 минут, от SYSTEM): применяет jobs.psd1, если он изменился,
    # и сообщает результат в бот заданием «jobs.psd1».
    $applied = Join-Path $Cfg.WorkDir 'jobs.applied'
    $last = ''
    if (Test-Path -LiteralPath $applied) { $last = [IO.File]::ReadAllText($applied).Trim() }
    if ((Get-JobsHash $Cfg) -eq $last) { return }
    $res = Invoke-Apply $Cfg
    if ($res.Errors.Count) { Save-AppliedHash $Cfg }   # не повторять ту же ошибку каждые 10 минут
    $status = 'ok'
    $lines = @()
    if ($res.Errors.Count) { $status = 'error'; $lines += 'Задачи не изменены, ошибки в jobs.psd1:'; $lines += $res.Errors }
    else {
        $lines += "Применено заданий: $($res.Applied.Count)"; $lines += $res.Applied
        foreach ($r in $res.Removed) { $lines += "удалено: $r" }
        if ($res.Warnings.Count) { $status = 'warning'; $lines += $res.Warnings }
    }
    $report = [ordered]@{
        run_id = [guid]::NewGuid().ToString(); job = $ConfigJobName; host = $Cfg.HostName; status = $status
        finished = Get-IsoNow; interval_hours = 0; message = ($lines -join "`n")
    }
    $null = Send-Report -Cfg $Cfg -Report $report
}

function Register-SyncTask {
    $triggers = '<CalendarTrigger><Repetition><Interval>PT10M</Interval><Duration>P1D</Duration><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>' +
        "<StartBoundary>$((Get-Date).ToString('yyyy-MM-dd'))T00:00:00</StartBoundary><Enabled>true</Enabled><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger>"
    $xml = New-AgentTaskXml -Description 'Агент бекапов: применяет изменения jobs.psd1 (раз в 10 минут)' `
        -ScriptPath (Join-Path $InstallDir 'Install-Agent.ps1') -Arguments ('-Sync -InstallDir "{0}"' -f $InstallDir) `
        -TriggersXml $triggers -TimeLimit 'PT30M'
    Register-ScheduledTask -TaskName '_Sync' -TaskPath $script:TaskFolder -Xml $xml -Force | Out-Null
    Write-Ok 'jobs.psd1 будет применяться сам в течение 10 минут после правки (итог придёт в бот)'
}

function Show-Jobs {
    Write-Step 'Задания в Планировщике'
    $rows = foreach ($t in @(Get-ScheduledTask -TaskPath $script:TaskFolder -ErrorAction SilentlyContinue)) {
        if ($t.TaskName.StartsWith('_')) { continue }
        $i = Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $script:TaskFolder
        $last = '—'
        if ($i.LastRunTime -and $i.LastRunTime.Year -gt 2000) { $last = '{0:dd.MM HH:mm} (код {1})' -f $i.LastRunTime, $i.LastTaskResult }
        $next = '—'
        if ($i.NextRunTime) { $next = '{0:dd.MM HH:mm}' -f $i.NextRunTime }
        New-Object PSObject -Property ([ordered]@{
            'Задание' = $t.TaskName; 'Состояние' = $t.State; 'Последний запуск' = $last; 'Следующий' = $next
        })
    }
    if ($rows) { $rows | Format-Table -AutoSize | Out-Host } else { Write-Warn 'заданий нет — опишите их в jobs.psd1' }
}

function Start-JobNow($Cfg, [string]$Name) {
    Write-Step "Запуск $Name"
    $log = Join-Path $Cfg.WorkDir 'agent.log'
    $skip = 0
    if (Test-Path -LiteralPath $log) { $skip = @(Get-Content -LiteralPath $log -Encoding UTF8).Count }
    Start-ScheduledTask -TaskName $Name -TaskPath $script:TaskFolder
    Start-Sleep -Seconds 3
    do {
        Start-Sleep -Seconds 3
        if (Test-Path -LiteralPath $log) {
            $lines = @(Get-Content -LiteralPath $log -Encoding UTF8)
            if ($lines.Count -gt $skip) { $lines[$skip..($lines.Count - 1)] | ForEach-Object { Write-Host "  $_" }; $skip = $lines.Count }
        }
        $state = (Get-ScheduledTask -TaskName $Name -TaskPath $script:TaskFolder).State
    } while ($state -eq 'Running')
    $info = Get-ScheduledTaskInfo -TaskName $Name -TaskPath $script:TaskFolder
    Write-Ok "завершено, код $($info.LastTaskResult) (0 — успешно, 1 — предупреждения, 2 — ошибка)"
}

# ---------- установка ----------
function Invoke-Setup {
    Install-AgentFiles
    $sevenZip = Install-SevenZip
    $cfgPath = Join-Path $InstallDir 'agent.config.psd1'
    $old = $null
    if (Test-Path -LiteralPath $cfgPath) { $old = Import-DataFile $cfgPath }
    $server = $null
    if ($old) {
        Write-Step 'Текущие настройки'
        try { Write-Ok ("сервер {0}, компания: {1}" -f $old.ServerUrl, (Test-ServerToken $old.ServerUrl $old.Token)); $server = $old }
        catch { Write-Warn $_.Exception.Message }
        if ($server -and (Read-YesNo 'Сменить сервер/токен?' $false)) { $server = $null }
    }
    if (-not $server) { $server = Read-ServerSettings $old }
    $values = @{ ServerUrl = $server.ServerUrl; Token = $server.Token; SevenZip = $sevenZip; NasRoot = $null }
    if ($old) { $values.NasRoot = $old.NasRoot }
    Save-AgentConfig $values $old            # конфиг нужен служебной задаче для проверки NAS от SYSTEM
    $cfg = Get-AgentConfig -Path $cfgPath

    if (-not $values.NasRoot -or (Read-YesNo "Сменить NAS ($($values.NasRoot))?" $false)) {
        $values.NasRoot = Read-NasRoot $cfg $old
        Save-AgentConfig $values $old
        $cfg = Get-AgentConfig -Path $cfgPath
    }
    Test-Vss $cfg

    Write-Step 'Задания'
    if (-not (Test-Path -LiteralPath $cfg.JobsFile)) {
        Copy-Item -LiteralPath (Join-Path $InstallDir 'jobs.example.psd1') -Destination $cfg.JobsFile
        Write-Ok "создан $($cfg.JobsFile) из примера"
    }
    Register-SyncTask
    if (Read-YesNo 'Открыть jobs.psd1 в Блокноте сейчас? После сохранения и закрытия задания применятся') {
        Start-Process notepad.exe -ArgumentList "`"$($cfg.JobsFile)`"" -Wait
        Show-ApplyResult (Invoke-Apply $cfg)
        Show-Jobs
    }
}

# При подключении через dot-source (тесты) только объявляем функции
if ($MyInvocation.InvocationName -ne '.') {
    try {
        if ($PSCmdlet.ParameterSetName -eq 'SystemHelper') {
            $cfg = Get-AgentConfig -Path (Join-Path $InstallDir 'agent.config.psd1')
            Invoke-SystemHelper $SystemHelper
            exit 0
        }
        Assert-Environment
        if ($PSCmdlet.ParameterSetName -eq 'Setup') { Invoke-Setup }
        else {
            $cfg = Get-AgentConfig -Path (Join-Path $InstallDir 'agent.config.psd1')
            switch ($PSCmdlet.ParameterSetName) {
                'Apply' { Show-ApplyResult (Invoke-Apply $cfg); Show-Jobs }
                'List' { Show-Jobs }
                'Run' { Start-JobNow $cfg $Run }
                'Sync' { Invoke-Sync $cfg }
                default { Invoke-CredentialCommand $cfg }
            }
        }
        Write-Host "`nГотово." -ForegroundColor Cyan
    } catch {
        Write-Host "`nОШИБКА: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
