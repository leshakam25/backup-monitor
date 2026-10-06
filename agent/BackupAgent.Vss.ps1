# Теневые копии тома (VSS): архивируем открытые файлы (базы 1С, PST, документы) со снимка,
# не выгоняя пользователей. Снимок создаётся через WMI — работает и на Windows 10/11,
# и на Server 2012 R2+ (vssadmin create shadow есть только на серверных ОС).
# Нужны права администратора/SYSTEM и 64-битный PowerShell.

$script:VssErrors = @{
    1 = 'нет прав (запускайте от администратора или SYSTEM)'
    2 = 'неверный параметр'
    3 = 'том не найден'
    4 = 'том не поддерживает снимки (не NTFS или сетевой диск?)'
    5 = 'контекст снимка не поддерживается'
    6 = 'недостаточно места под теневые копии на томе'
    7 = 'том занят'
    8 = 'достигнут предел числа теневых копий'
    9 = 'другая операция VSS уже выполняется'
    10 = 'поставщик VSS отказал'
    11 = 'поставщик VSS не зарегистрирован'
    12 = 'сбой поставщика VSS'
}

function Get-VssStateFile { param($Cfg) Join-Path $Cfg.WorkDir 'vss\active.txt' }

function New-VssSnapshot {
    # Создаёт снимок тома и делает на него ссылку-папку. Возвращает @{Id; Volume; Link}.
    param($Cfg, [string]$Volume)
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        # без прав WMI отвечает невнятным «Сбой инициализации»
        throw 'нет прав администратора (задания Планировщика работают от SYSTEM; вручную — запускайте от администратора)'
    }
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        throw '32-битный PowerShell: снимки VSS доступны только из 64-битного'
    }
    $vssDir = Join-Path $Cfg.WorkDir 'vss'
    if (-not (Test-Path -LiteralPath $vssDir)) { New-Item -ItemType Directory -Path $vssDir -Force | Out-Null }

    $r = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $r = Invoke-CimMethod -ClassName Win32_ShadowCopy -MethodName Create `
            -Arguments @{ Volume = $Volume; Context = 'ClientAccessible' }
        if ($r.ReturnValue -ne 9) { break }   # 9 — занято другой операцией VSS, подождём
        Start-Sleep -Seconds 30
    }
    if ($r.ReturnValue -ne 0) {
        $why = $script:VssErrors[[int]$r.ReturnValue]
        if (-not $why) { $why = 'неизвестная ошибка' }
        throw ("снимок {0} не создан: {1} (код {2})" -f $Volume, $why, $r.ReturnValue)
    }
    $shadow = Get-CimInstance -ClassName Win32_ShadowCopy -Filter ("ID='{0}'" -f $r.ShadowID)
    $link = Join-Path $vssDir ('vol_' + $Volume.Substring(0, 1))
    # состояние пишем ДО ссылки: если процесс упадёт, следующий запуск удалит и снимок, и ссылку
    [IO.File]::AppendAllText((Get-VssStateFile $Cfg), ('{0}|{1}' -f $r.ShadowID, $link) + [Environment]::NewLine)
    if (Test-Path -LiteralPath $link) { Remove-VssLink $link }
    $out = & cmd.exe /c mklink /d "$link" "$($shadow.DeviceObject)\" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "не удалось подключить снимок ${Volume}: $out" }
    return @{ Id = $r.ShadowID; Volume = $Volume; Link = $link }
}

function Remove-VssLink {
    # rmdir удаляет только ссылку, не трогая содержимое снимка (Remove-Item в PS 5.1 может пойти внутрь)
    param([string]$Link)
    if (Test-Path -LiteralPath $Link) { & cmd.exe /c rmdir "$Link" 2>&1 | Out-Null }
}

function Remove-VssSnapshot {
    param($Cfg, $Snapshot)
    Remove-VssLink $Snapshot.Link
    Get-CimInstance -ClassName Win32_ShadowCopy -Filter ("ID='{0}'" -f $Snapshot.Id) | Remove-CimInstance
}

function Clear-StaleVss {
    # Удаляет снимки и ссылки, оставшиеся от аварийно завершённых запусков.
    # Трогаем только свои снимки (по списку), чужие (точки восстановления, Windows Backup) — нет.
    param($Cfg)
    $state = Get-VssStateFile $Cfg
    if (-not (Test-Path -LiteralPath $state)) { return }
    foreach ($line in [IO.File]::ReadAllLines($state)) {
        $parts = $line -split '\|', 2
        if ($parts.Count -ne 2) { continue }
        try {
            Remove-VssSnapshot -Cfg $Cfg -Snapshot @{ Id = $parts[0]; Link = $parts[1] }
            Write-AgentLog "Удалён оставшийся снимок VSS $($parts[0])"
        } catch { Write-AgentLog "Не удалось удалить старый снимок $($parts[0]): $($_.Exception.Message)" }
    }
    Remove-Item -LiteralPath $state -Force
}

function Clear-VssState {
    param($Cfg)
    $state = Get-VssStateFile $Cfg
    if (Test-Path -LiteralPath $state) { Remove-Item -LiteralPath $state -Force }
}

function Get-VolumeRoot {
    # D:\1C\Buh -> D:\ ; для UNC и относительных путей — $null (снимок невозможен)
    param([string]$Path)
    if ($Path -notmatch '^[A-Za-z]:\\') { return $null }
    return $Path.Substring(0, 3).ToUpper()
}

function Convert-ToSnapshotPath {
    # D:\1C\Buh -> C:\BackupAgent\data\vss\vol_D\1C\Buh
    param([string]$Path, [hashtable]$Snapshots)
    $root = Get-VolumeRoot $Path
    if (-not $root -or -not $Snapshots.ContainsKey($root)) { return $Path }
    $rest = $Path.Substring(3)
    if (-not $rest) { return $Snapshots[$root].Link + '\' }   # источник — корень тома
    return Join-Path $Snapshots[$root].Link $rest
}
