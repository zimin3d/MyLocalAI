# =====================================================================
#  Подключение облачных моделей (DeepSeek, Kimi) ко «Второму мозгу»
#
#  Запуск: двойной клик по "ПОДКЛЮЧИТЬ_ОБЛАКО.cmd" (после УСТАНОВИТЬ.cmd).
#  Спрашивает провайдера и API-ключ, проверяет ключ, сохраняет его в
#  настройки omp (%USERPROFILE%\.omp\agent\.env — вне папки заметок, так что
#  ИИ его прочитать не может) и кладёт ярлык на рабочий стол.
#  Повторный запуск позволяет заменить ключ или отключить облако.
# =====================================================================

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ProgressPreference = "SilentlyContinue"

$AgentDir = Join-Path $env:USERPROFILE ".omp\agent"
$EnvFile = Join-Path $AgentDir ".env"
$GuardHook = Join-Path $AgentDir "hooks\pre\vault-guard.ts"
$OmpExe = Join-Path $env:LOCALAPPDATA "omp\omp.exe"
$Desktop = [Environment]::GetFolderPath("Desktop")
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

# Model ids are tried in order against the provider's live model list; the
# first one the account can use wins, so a renamed model does not break setup.
$Providers = [ordered]@{
    "1" = @{
        Name = "DeepSeek"; Id = "deepseek"; KeyVar = "DEEPSEEK_API_KEY"
        Endpoints = @("https://api.deepseek.com")
        Models = @("deepseek-v4-pro", "deepseek-v4-flash", "deepseek-flash")
        KeyUrl = "https://platform.deepseek.com/api_keys"
        Where = "Китай (DeepSeek)"
    }
    "2" = @{
        Name = "Kimi"; Id = "moonshot"; KeyVar = "MOONSHOT_API_KEY"
        # International platform first, then the China one (needs MOONSHOT_BASE_URL).
        Endpoints = @("https://api.moonshot.ai/v1", "https://api.moonshot.cn/v1")
        Models = @("kimi-k3.1-pro", "kimi-k3", "kimi-k2.7-code")
        KeyUrl = "https://platform.moonshot.ai/console/api-keys"
        Where = "Китай (Moonshot AI)"
    }
}

function Write-Ok([string]$Text)   { Write-Host "    [OK] $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "    [!]  $Text" -ForegroundColor Yellow }
function Write-Info([string]$Text) { Write-Host "         $Text" }

function Stop-WithError([string]$Text) {
    Write-Host ""
    Write-Host "ОШИБКА: $Text" -ForegroundColor Red
    exit 1
}

function Read-EnvLines {
    if (Test-Path -LiteralPath $EnvFile) {
        return @([System.IO.File]::ReadAllLines($EnvFile, $Utf8NoBom))
    }
    return @()
}

# Rewrites .env with `$Name` removed, then appended with `$Value` when given;
# every other line is kept as it was.
function Set-EnvValue([string]$Name, [string]$Value) {
    $lines = @(Read-EnvLines | Where-Object { $_ -notmatch "^\s*(export\s+)?$([regex]::Escape($Name))\s*=" })
    if ($Value) { $lines += "$Name=$Value" }
    New-Item -ItemType Directory -Force -Path $AgentDir | Out-Null
    [System.IO.File]::WriteAllLines($EnvFile, [string[]]$lines, $Utf8NoBom)
}

function Get-EnvValue([string]$Name) {
    foreach ($line in Read-EnvLines) {
        if ($line -match "^\s*(export\s+)?$([regex]::Escape($Name))\s*=\s*(.*)$") { return $Matches[2].Trim() }
    }
    return ""
}

# The installer bakes the vault path into the guard hook as a JSON string.
function Get-VaultPath {
    if (-not (Test-Path -LiteralPath $GuardHook)) { return "" }
    $text = [System.IO.File]::ReadAllText($GuardHook, $Utf8NoBom)
    $m = [regex]::Match($text, '(?m)^const VAULT = (".*");\s*$')
    if (-not $m.Success) { return "" }
    return [string]($m.Groups[1].Value | ConvertFrom-Json)
}

function Get-ShortcutPath($Provider) {
    return Join-Path $Desktop "Второй мозг — $($Provider.Name) (облако).lnk"
}

# Returns @{ BaseUrl; Models } for the first endpoint that accepts the key,
# or $null when none does.
function Test-ApiKey($Provider, [string]$Key) {
    foreach ($base in $Provider.Endpoints) {
        try {
            $answer = Invoke-RestMethod -Uri "$base/models" -Headers @{ Authorization = "Bearer $Key" } -TimeoutSec 20
            return @{ BaseUrl = $base; Models = @($answer.data | ForEach-Object { $_.id }) }
        } catch {
            $status = $null
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }
            if ($status -ne 401 -and $status -ne 403) {
                Write-Warn "Не удалось связаться с $base : $($_.Exception.Message)"
            }
        }
    }
    return $null
}

# ---------------------------------------------------------------- start

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Magenta
Write-Host "   Подключение облачной модели ко «Второму мозгу»" -ForegroundColor Magenta
Write-Host "=================================================================" -ForegroundColor Magenta

if (-not (Test-Path -LiteralPath $OmpExe)) {
    Stop-WithError "Сначала установите «Второй мозг»: запустите УСТАНОВИТЬ.cmd."
}
$VaultPath = Get-VaultPath
if (-not $VaultPath) {
    Stop-WithError "Не найдено ограничение папкой заметок. Запустите УСТАНОВИТЬ.cmd ещё раз."
}

Write-Host ""
Write-Host "Что сделать?"
foreach ($k in $Providers.Keys) {
    $p = $Providers[$k]
    $state = if (Get-EnvValue $p.KeyVar) { "  (уже подключён)" } else { "" }
    Write-Host "  $k) Подключить $($p.Name)$state"
}
Write-Host "  3) Отключить облачные модели"
$choice = (Read-Host "Введите номер и нажмите Enter").Trim()

if ($choice -eq "3") {
    foreach ($p in $Providers.Values) {
        Set-EnvValue $p.KeyVar ""
        if ($p.Id -eq "moonshot") { Set-EnvValue "MOONSHOT_BASE_URL" "" }
        Remove-Item -LiteralPath (Get-ShortcutPath $p) -Force -ErrorAction SilentlyContinue
    }
    Write-Ok "Облачные модели отключены, ключи удалены, ярлыки убраны."
    exit 0
}
if (-not $Providers.Contains($choice)) {
    Stop-WithError "Нет такого варианта."
}
$Provider = $Providers[$choice]

Write-Host ""
Write-Host "ВАЖНО — прочитайте перед подключением:" -ForegroundColor Yellow
Write-Host "  • С облачной моделью ваши вопросы и содержимое заметок, которые"
Write-Host "    помощник прочитает, отправляются на серверы: $($Provider.Where)."
Write-Host "    Не храните в «Втором мозге» то, что нельзя показывать посторонним"
Write-Host "    (пароли, документы, медицинские данные), если пользуетесь облаком."
Write-Host "  • Облако платное: деньги списываются с баланса на сайте $($Provider.Name)."
Write-Host "  • Ограничение папкой заметок действует и для облачной модели."
Write-Host "  • Локальные ярлыки продолжают работать без интернета, как раньше."
$agree = (Read-Host "Подключить $($Provider.Name)? Введите Д (да) или Н (нет)").Trim().ToLower()
if ($agree -notin @("д", "да", "y", "yes")) {
    Write-Info "Отменено, ничего не изменено."
    exit 0
}

Write-Host ""
Write-Host "Ключ берётся на сайте: $($Provider.KeyUrl)"
Write-Host "(войдите, пополните баланс, создайте ключ и скопируйте его)"
$secure = Read-Host "Вставьте ключ (символы не видны — это нормально) и нажмите Enter" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try { $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr).Trim() } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
if (-not $key) { Stop-WithError "Ключ пустой." }

Write-Info "Проверяю ключ..."
$check = Test-ApiKey $Provider $key
if (-not $check) {
    Stop-WithError "$($Provider.Name) не принял ключ. Проверьте, что он скопирован целиком и баланс пополнен."
}
$model = $Provider.Models | Where-Object { $check.Models -contains $_ } | Select-Object -First 1
if (-not $model) {
    $model = $check.Models | Select-Object -First 1
    if (-not $model) { Stop-WithError "$($Provider.Name) не вернул ни одной модели для этого ключа." }
    Write-Warn "Рекомендованных моделей нет в вашем аккаунте, беру $model."
}
Write-Ok "Ключ принят, модель: $model"

Set-EnvValue $Provider.KeyVar $key
if ($Provider.Id -eq "moonshot") {
    # The China platform needs its own base URL; the international one is omp's default.
    if ($check.BaseUrl -like "*moonshot.cn*") { Set-EnvValue "MOONSHOT_BASE_URL" $check.BaseUrl }
    else { Set-EnvValue "MOONSHOT_BASE_URL" "" }
}
Write-Ok "Ключ сохранён в $EnvFile"

$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut((Get-ShortcutPath $Provider))
$link.TargetPath = Join-Path $env:SystemRoot "System32\cmd.exe"
$link.Arguments = "/k cd /d `"$VaultPath`" && `"$OmpExe`" --model $($Provider.Id)/$model"
$link.WorkingDirectory = $VaultPath
$link.IconLocation = "$OmpExe,0"
$link.Description = "Помощник на облачной модели $($Provider.Name) ($model)"
$link.Save()
Write-Ok "Ярлык «Второй мозг — $($Provider.Name) (облако)» на рабочем столе"

Write-Host ""
Write-Host "ГОТОВО! Откройте ярлык «Второй мозг — $($Provider.Name) (облако)»." -ForegroundColor Green
Write-Host "Другую модель $($Provider.Name) можно выбрать в окне помощника командой /model."
