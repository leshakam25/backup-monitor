# Общие функции агента мониторинга бекапов.
# Подключается из Backup-Job.ps1, Send-BackupReport.ps1 и Install-Agent.ps1.
# Совместим с Windows PowerShell 4.0 (Server 2012 R2) и 5.1.

$script:AgentVersion = '2.0'
$script:OnWindows = ($PSVersionTable.PSEdition -ne 'Core') -or ($IsWindows -eq $true)
# Доп. энтропия DPAPI: секрет расшифруется только этим агентом и только на этой машине
$script:SecretEntropy = [Text.Encoding]::UTF8.GetBytes('BackupAgent/v1')

. (Join-Path $PSScriptRoot 'BackupAgent.Vss.ps1')
. (Join-Path $PSScriptRoot 'BackupAgent.Creds.ps1')
. (Join-Path $PSScriptRoot 'BackupAgent.Jobs.ps1')

function Read-TextFile {
    # Читает текст в нужной кодировке: 'auto' (UTF-8, если файл им является, иначе $Fallback),
    # 'oem' (вывод cmd/bat, cp866), 'utf8', 'ansi' (cp1251) или номер кодовой страницы.
    param([string]$Path, [string]$Encoding = 'auto', [string]$Fallback = 'oem')
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    if ($Encoding -eq 'auto') {
        $bytes = [IO.File]::ReadAllBytes($Path)
        try { return (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes).TrimStart([char]0xFEFF) }
        catch { $Encoding = $Fallback }
    }
    switch ($Encoding.ToLower()) {
        'utf8' { $enc = [Text.Encoding]::UTF8 }
        'oem'  { $enc = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) }
        'ansi' { $enc = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage) }
        default { $enc = [Text.Encoding]::GetEncoding([int]$Encoding) }
    }
    return [IO.File]::ReadAllText($Path, $enc)
}

function Import-DataFile {
    # Аналог Import-PowerShellDataFile, которого нет в PowerShell 4.
    # Файл выполняется в режиме restricted language: только литералы, без команд и переменных.
    # Кодировка: UTF-8 или ANSI (Блокнот на Server 2012 R2 по умолчанию сохраняет в ANSI).
    param([string]$Path)
    $text = Read-TextFile -Path $Path -Fallback 'ansi'
    if ($null -eq $text) { throw "Не найден файл: $Path" }
    try {
        $sb = [scriptblock]::Create($text)
        $sb.CheckRestrictedLanguage([string[]]@(), [string[]]@('true', 'false', 'null'), $false)
        $data = & $sb
    } catch {
        throw "Ошибка в файле ${Path}: $($_.Exception.Message)"
    }
    if ($data -isnot [hashtable]) { throw "Файл $Path должен содержать @{ ... }" }
    return $data
}

function Set-DefaultValue {
    param([hashtable]$Table, [string]$Key, $Value)
    if (-not $Table.ContainsKey($Key) -or $null -eq $Table[$Key] -or ($Table[$Key] -is [string] -and $Table[$Key] -eq '')) {
        $Table[$Key] = $Value
    }
}

function Get-AgentConfig {
    param([string]$Path)
    if (-not $Path) { $Path = Join-Path $PSScriptRoot 'agent.config.psd1' }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Не найден файл настроек: $Path" }
    $cfg = Import-DataFile -Path $Path
    foreach ($key in 'ServerUrl', 'Token') {
        if (-not $cfg[$key]) { throw "В $Path не задан параметр $key" }
    }
    Set-DefaultValue $cfg 'SevenZip' 'C:\Program Files\7-Zip\7z.exe'
    Set-DefaultValue $cfg 'HostName' ([Environment]::MachineName)
    Set-DefaultValue $cfg 'WorkDir' (Join-Path $PSScriptRoot 'data')
    Set-DefaultValue $cfg 'StagingDir' (Join-Path $cfg.WorkDir 'staging')
    Set-DefaultValue $cfg 'JobsFile' (Join-Path $PSScriptRoot 'jobs.psd1')
    Set-DefaultValue $cfg 'NasRoot' $null
    Set-DefaultValue $cfg 'UseVss' $true
    Set-DefaultValue $cfg 'KeepDays' 14
    Set-DefaultValue $cfg 'MinKeep' 3
    Set-DefaultValue $cfg 'Format' '7z'
    Set-DefaultValue $cfg 'Level' 5
    Set-DefaultValue $cfg 'LockTimeoutMinutes' 720
    Set-DefaultValue $cfg 'QueueLimit' 500
    Set-DefaultValue $cfg 'LogKeepDays' 30
    $cfg.ConfigPath = $Path
    foreach ($dir in $cfg.WorkDir, (Join-Path $cfg.WorkDir 'queue'), (Join-Path $cfg.WorkDir 'logs'), $cfg.StagingDir) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }
    $script:AgentLogFile = Join-Path $cfg.WorkDir 'agent.log'
    return $cfg
}

function Write-AgentLog {
    param([string]$Text)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
    Write-Host $line
    if ($script:AgentLogFile) {
        try {
            # не даём логу агента расти бесконечно
            $f = Get-Item -LiteralPath $script:AgentLogFile -ErrorAction SilentlyContinue
            if ($f -and $f.Length -gt 5MB) { Move-Item -LiteralPath $f.FullName -Destination ($f.FullName + '.old') -Force }
            [IO.File]::AppendAllText($script:AgentLogFile, $line + [Environment]::NewLine, [Text.Encoding]::UTF8)
        } catch { }
    }
}

function Get-IsoNow { (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz') }

# ---------- секреты (пароли архивов в jobs.psd1) ----------
function Protect-Secret {
    # Шифрует ключом машины (DPAPI LocalMachine): задания от SYSTEM смогут прочитать,
    # а файл, унесённый на другой компьютер, — нет.
    param([string]$Plain)
    Add-Type -AssemblyName System.Security
    $bytes = [Text.Encoding]::UTF8.GetBytes($Plain)
    $enc = [Security.Cryptography.ProtectedData]::Protect($bytes, $script:SecretEntropy,
        [Security.Cryptography.DataProtectionScope]::LocalMachine)
    return 'dpapi:' + [Convert]::ToBase64String($enc)
}

function Unprotect-Secret {
    param([string]$Value)
    if (-not $Value -or -not $Value.StartsWith('dpapi:')) { return $Value }
    Add-Type -AssemblyName System.Security
    try {
        $bytes = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Value.Substring(6)),
            $script:SecretEntropy, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    } catch {
        throw 'Не удалось расшифровать пароль архива: он зашифрован на другой машине. Впишите его в jobs.psd1 заново открытым текстом'
    }
    return [Text.Encoding]::UTF8.GetString($bytes)
}

# ---------- очередь заданий: на машине выполняется только одно задание ----------
function Enter-AgentLock {
    # Возвращает мьютекс или $null, если не дождались. Права выдаются SYSTEM и администраторам,
    # чтобы ручной запуск от администратора видел мьютекс, созданный заданием от SYSTEM.
    param([int]$TimeoutMinutes)
    $name = 'Global\BackupAgentJobs'
    try {
        $sec = New-Object Security.AccessControl.MutexSecurity
        foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {
            $rule = New-Object Security.AccessControl.MutexAccessRule((New-Object Security.Principal.SecurityIdentifier $sid),
                [Security.AccessControl.MutexRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow)
            $sec.AddAccessRule($rule)
        }
        $created = $false
        $m = New-Object Threading.Mutex($false, $name, [ref]$created, $sec)
    } catch {
        try { $m = New-Object Threading.Mutex($false, $name) }
        catch { throw 'Нет доступа к очереди заданий: запускайте агент от администратора (задания Планировщика работают от SYSTEM)' }
    }
    try {
        if ($m.WaitOne([TimeSpan]::FromMinutes($TimeoutMinutes))) { return $m }
    } catch [Threading.AbandonedMutexException] {
        return $m   # предыдущий процесс упал, не отпустив очередь, — она наша
    }
    $m.Dispose()
    return $null
}

function Exit-AgentLock {
    param($Mutex)
    if (-not $Mutex) { return }
    try { $Mutex.ReleaseMutex() } catch { }
    $Mutex.Dispose()
}

# ---------- диск ----------
function Get-FreeBytes {
    # Свободное место на диске/шаре, где лежит путь. Работает и для UNC (\\nas\backup).
    param([string]$Path)
    try {
        if ($script:OnWindows) {
            if (-not ('BackupAgent.Disk' -as [type])) {
                Add-Type -Namespace BackupAgent -Name Disk -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool GetDiskFreeSpaceEx(string lpDirectoryName, out ulong lpFreeBytesAvailable,
    out ulong lpTotalNumberOfBytes, out ulong lpTotalNumberOfFreeBytes);
'@
            }
            $free = [uint64]0; $total = [uint64]0; $totalFree = [uint64]0
            if ([BackupAgent.Disk]::GetDiskFreeSpaceEx($Path, [ref]$free, [ref]$total, [ref]$totalFree)) {
                return [int64]$free
            }
        } else {
            $out = & df -P -B1 $Path 2>$null | Select-Object -Last 1
            if ($out) { return [int64](($out -split '\s+')[3]) }
        }
    } catch { }
    return $null
}

function Get-ErrorDigest {
    # Из вывода 7-Zip вытаскивает строки с ошибками/предупреждениями и хвост лога.
    param([string]$Text, [int]$TailLines = 15, [int]$MaxChars = 3500)
    if (-not $Text) { return $null }
    $lines = $Text -split "`r?`n" | Where-Object { $_.Trim() -ne '' }
    $important = $lines | Where-Object { $_ -match 'WARNING|ERROR|Cannot|can not|denied|not find|Отказано|не удается|не удаётся|Ошибка' } |
        Select-Object -First 25
    $tail = $lines | Select-Object -Last $TailLines
    $result = @()
    if ($important) { $result += $important; $result += '---' }
    $result += $tail
    $s = ($result -join "`n")
    if ($s.Length -gt $MaxChars) { $s = $s.Substring(0, $MaxChars) + '…' }
    return $s
}

function Get-StatusFromExitCode {
    param([int]$ExitCode)
    switch ($ExitCode) {
        0 { 'ok' }
        1 { 'warning' }   # 7-Zip: некритичные ошибки (обычно занятые файлы)
        default { 'error' }
    }
}

# ---------- связь с сервером ----------
function Enable-Tls12 {
    # Server 2012 R2 / PowerShell 4 по умолчанию не включает TLS 1.2
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
}

function Get-ServerBase {
    # https://backup.example.ru/api/report -> https://backup.example.ru
    param([string]$ServerUrl)
    return ($ServerUrl -replace '/api/report/?$', '').TrimEnd('/')
}

function Invoke-ReportPost {
    # Возвращает 'sent', 'retry' (сервер недоступен — оставить в очереди) или 'drop' (сервер отверг отчёт).
    param($Cfg, [string]$Json)
    Enable-Tls12
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Json)
        Invoke-RestMethod -Uri $Cfg.ServerUrl -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' `
            -Headers @{ 'X-Token' = $Cfg.Token } -TimeoutSec 30 -UseBasicParsing | Out-Null
        return 'sent'
    } catch {
        $code = $null
        try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        $codeText = 'нет ответа'
        if ($code) { $codeText = "HTTP $code" }
        Write-AgentLog ("Не удалось отправить отчёт ({0}): {1}" -f $codeText, $_.Exception.Message)
        if ($code -eq 400) { return 'drop' }   # отчёт некорректен — повтор не поможет
        return 'retry'                         # нет сети, сервер лежит, неверный токен (401) — попробуем позже
    }
}

function Send-QueuedReports {
    param($Cfg)
    $queueDir = Join-Path $Cfg.WorkDir 'queue'
    $files = @(Get-ChildItem -LiteralPath $queueDir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($f in $files) {
        $json = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
        $res = Invoke-ReportPost -Cfg $Cfg -Json $json
        if ($res -eq 'retry') { return $false }
        Remove-Item -LiteralPath $f.FullName -Force
        Write-AgentLog "Отправлен отчёт из очереди: $($f.Name) ($res)"
    }
    return $true
}

function Send-Report {
    # Отправляет отчёт; если сервер недоступен — кладёт в очередь, она дошлётся при следующем запуске.
    param($Cfg, [System.Collections.IDictionary]$Report)
    $Report['agent_version'] = $script:AgentVersion
    $json = $Report | ConvertTo-Json -Depth 4 -Compress

    $queueOk = Send-QueuedReports -Cfg $Cfg
    $res = 'retry'
    if ($queueOk) { $res = Invoke-ReportPost -Cfg $Cfg -Json $json }

    if ($res -eq 'retry') {
        $queueDir = Join-Path $Cfg.WorkDir 'queue'
        $name = '{0}_{1}.json' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $Report['run_id']
        [IO.File]::WriteAllText((Join-Path $queueDir $name), $json, (New-Object Text.UTF8Encoding $false))
        Write-AgentLog "Отчёт сохранён в очередь: $name"
        $all = @(Get-ChildItem -LiteralPath $queueDir -Filter '*.json' | Sort-Object Name)
        if ($all.Count -gt $Cfg.QueueLimit) {
            $all | Select-Object -First ($all.Count - $Cfg.QueueLimit) | Remove-Item -Force
        }
        return $false
    }
    Write-AgentLog "Отчёт отправлен: $($Report['job']) — $($Report['status'])"
    return $true
}

function Remove-OldLogs {
    param($Cfg)
    $border = (Get-Date).AddDays(-[int]$Cfg.LogKeepDays)
    Get-ChildItem -LiteralPath (Join-Path $Cfg.WorkDir 'logs') -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $border } | Remove-Item -Force -ErrorAction SilentlyContinue
}
