# ============================================================================
# Деплой бота мониторинга бекапов на сервер с внешним Traefik и AWG-прокси (в /opt/backup_bot)
# ============================================================================
# Доставляет server/ + docker-compose.yml + .env.example. .env на сервере НЕ перезаписывается
# (при первом деплое создаётся из примера — впишите в него DOMAIN, BOT_TOKEN, ADMIN_IDS).
#
#   pwsh ./deploy/shared-host/deploy.ps1 -VdsHost my-vps        # только доставить файлы
#   pwsh ./deploy/shared-host/deploy.ps1 -VdsHost my-vps -Up    # + собрать и (пере)запустить бота
#
# Трогает ТОЛЬКО контейнер backup-bot. Внешние Traefik и AWG-прокси не пересоздаёт.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VdsHost,        # ssh-алиас или user@host
    [string]$RemoteDir = "/opt/backup_bot",
    [switch]$Up
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # корень репозитория
$tar = Join-Path ([IO.Path]::GetTempPath()) "backup_bot_deploy.tgz"
$PlaceholderUrl = 'https://backup.example.ru/api/report'          # адрес по умолчанию в исходниках агента

function Invoke-Remote([string]$Cmd) {
    & ssh $VdsHost $Cmd
    if ($LASTEXITCODE -ne 0) { throw "ssh: команда завершилась с кодом ${LASTEXITCODE}: $Cmd" }
}

function Get-RemoteDomain {
    # DOMAIN из .env на сервере: его подставляем в архив агента как адрес сервера по умолчанию
    $line = & ssh $VdsHost "grep -E '^DOMAIN=.+' $RemoteDir/.env 2>/dev/null | tail -1"
    if ($line -match '^DOMAIN=(.+)$') { return $Matches[1].Trim().Trim('"').Trim("'") }
    return $null
}

function New-AgentZip([string]$ServerUrl) {
    # Только файлы агента (без локальных agent.config.psd1 / jobs.psd1 с токенами), в папке BackupAgent
    $agentFiles = 'Install.cmd', 'Install-Agent.ps1', 'Backup-Job.ps1', 'Send-BackupReport.ps1', 'BackupAgent.Common.ps1',
        'BackupAgent.Vss.ps1', 'BackupAgent.Creds.ps1', 'BackupAgent.Jobs.ps1', 'agent.config.example.psd1', 'jobs.example.psd1'
    $pack = Join-Path ([IO.Path]::GetTempPath()) "backup_agent_pack\BackupAgent"
    if (Test-Path $pack) { Remove-Item (Split-Path $pack) -Recurse -Force }
    New-Item -ItemType Directory -Path $pack -Force | Out-Null
    foreach ($f in $agentFiles) { Copy-Item (Join-Path $root "agent\$f") $pack }
    if ($ServerUrl) {
        foreach ($f in 'Install-Agent.ps1', 'agent.config.example.psd1') {
            $path = Join-Path $pack $f
            $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
            [IO.File]::WriteAllText($path, $text.Replace($PlaceholderUrl, $ServerUrl), (New-Object Text.UTF8Encoding $true))
        }
    }
    $zip = Join-Path $root 'server\backup_bot\static\backup-agent.zip'
    Compress-Archive -Path $pack -DestinationPath $zip -Force
    Remove-Item (Split-Path $pack) -Recurse -Force
}

Write-Host "=== архив агента для страницы установки ===" -ForegroundColor Green
$domain = Get-RemoteDomain
if ($domain) {
    New-AgentZip "https://$domain/api/report"
    Write-Host "  адрес сервера в установщике: https://$domain" -ForegroundColor DarkGray
} else {
    New-AgentZip $null
    Write-Host "  ! DOMAIN в $RemoteDir/.env не задан — в установщике останется $PlaceholderUrl" -ForegroundColor Yellow
}

Write-Host "=== упаковка server/ ===" -ForegroundColor Green
& tar -czf $tar -C $root --exclude=__pycache__ --exclude=*.pyc --exclude=tests --exclude=.env --exclude=*.sqlite3* server
if ($LASTEXITCODE -ne 0) { throw "tar не удался" }

Write-Host "=== доставка на ${VdsHost}:$RemoteDir ===" -ForegroundColor Green
Invoke-Remote "mkdir -p $RemoteDir"
& scp $tar "${VdsHost}:/tmp/backup_bot_deploy.tgz"
if ($LASTEXITCODE -ne 0) { throw "scp архива не удался" }
& scp (Join-Path $PSScriptRoot "docker-compose.yml") (Join-Path $PSScriptRoot ".env.example") "${VdsHost}:$RemoteDir/"
if ($LASTEXITCODE -ne 0) { throw "scp compose не удался" }
Remove-Item $tar -Force
Invoke-Remote ("cd $RemoteDir && rm -rf server && tar -xzf /tmp/backup_bot_deploy.tgz && rm -f /tmp/backup_bot_deploy.tgz && chmod -R go-w server" +
    " && { [ -f .env ] || { cp .env.example .env && echo '.env создан из примера: впишите DOMAIN и BOT_TOKEN'; }; } && chmod 600 .env")

if ($Up) {
    # Без токена бот уйдёт в цикл рестартов — не запускаем
    & ssh $VdsHost "grep -Eq '^BOT_TOKEN=.+' $RemoteDir/.env"
    if ($LASTEXITCODE -ne 0) { throw "В ${RemoteDir}/.env не задан BOT_TOKEN" }
    # Внешние сети должны существовать — иначе compose up упадёт
    foreach ($net in 'awg_backup', 'backup_proxy') {
        & ssh $VdsHost "docker network inspect $net >/dev/null 2>&1"
        if ($LASTEXITCODE -ne 0) { throw "Нет сети $net (её создают внешние стеки AWG-прокси / Traefik)" }
    }

    Write-Host "=== сборка и запуск ===" -ForegroundColor Green
    Invoke-Remote "cd $RemoteDir && docker compose up -d --build && docker compose ps"
    Write-Host "Логи: ssh $VdsHost 'cd $RemoteDir && docker compose logs -f bot'" -ForegroundColor DarkGray
}

Write-Host "`nГотово." -ForegroundColor Cyan
