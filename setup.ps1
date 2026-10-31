# =====================================================================
#  "Второй мозг" на Windows 11: Oh My Pi + локальные модели + Obsidian
#
#  Что делает скрипт (можно запускать повторно — уже сделанное пропускается):
#    1. Проверяет видеокарту NVIDIA и драйвер
#    2. Ставит Git (нужен omp для команд), Ollama (локальные модели), Obsidian (заметки)
#    3. Настраивает Ollama под 12 ГБ видеопамяти и скачивает модели:
#       qwen3.5:9b (основная), qwen3.5:4b (быстрая), bonsai-2:27b («умный режим»)
#    4. Ставит Oh My Pi (omp), подключает его к локальным моделям и запирает
#       в папке заметок (хук vault-guard.ts: файлы вне папки, команды и код недоступны)
#    5. Создаёт хранилище заметок "Второй мозг" с инструкцией для ИИ
#    6. Ставит генерацию картинок: ComfyUI + Qwen-Image 2.1 Uncensored
#    7. Кладёт ярлыки на рабочий стол и проверяет, что модель работает на видеокарте
#
#  Запуск: двойной клик по "УСТАНОВИТЬ.cmd" (лежит рядом).
#  В начале скрипт спросит, на какой диск сохранить модели и ComfyUI.
#  Параметры (для опытных):
#    -InstallRoot "D:\MyLocalAI"  папка для моделей, ComfyUI и заметок (без вопроса о диске)
#    -VaultPath "D:\Заметки"   своё место для заметок
#    -SkipModels               не скачивать модели
#    -MainModel / -FastModel   другие модели Ollama
#    -SmartModel ""            не ставить модель для «умного режима»
#    -SkipImages               не ставить генерацию картинок (~20 ГБ)
#    -ImagesPath "D:\AI"       куда ставить ComfyUI (по умолчанию — папка установки)
# =====================================================================

param(
    [string]$VaultPath = "",
    [string]$MainModel = "qwen3.5:9b",
    [string]$FastModel = "qwen3.5:4b",
    [string]$SmartModel = "bonsai-2:27b",
    [int]$ContextLength = 32768,
    [switch]$SkipModels,
    [switch]$SkipImages,
    [string]$ImagesPath = "",
    [string]$InstallRoot = ""
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ProgressPreference = "SilentlyContinue"

$LogFile = Join-Path $env:TEMP "second-brain-setup.log"
try { Start-Transcript -Path $LogFile -Append | Out-Null } catch { }

$OllamaUrl = "http://127.0.0.1:11434"
$OmpExe = Join-Path $env:LOCALAPPDATA "omp\omp.exe"
$ObsidianExe = Join-Path $env:LOCALAPPDATA "Programs\Obsidian\Obsidian.exe"
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

# Image generation: ComfyUI portable + Qwen-Image 2.1 Uncensored. Versions and
# checksums are pinned so a re-run downloads exactly the files tested here.
$ComfyVersion = "v0.43.0"
$ComfyArchiveUrl = "https://github.com/Comfy-Org/ComfyUI/releases/download/$ComfyVersion/ComfyUI_windows_portable_nvidia.7z"
$ComfyArchiveSha256 = "4928f88e6a8407c4574d4f7d92cfeba020d782edba4a076b7d107ecc98955e50"
$ImageRepo = "https://huggingface.co/abenzerps/Qwen-Image-2.1-Uncensored-Quantized/resolve/7959e658915f52274897fb573ffeda49de8dc16b"
$ImageFiles = @(
    @{ Title = "модель картинок (6,8 ГБ)"; Remote = "qwen-image-2.1-UC-int8_convrot.safetensors"; Folder = "diffusion_models"
       Sha256 = "5bc5a6c007eff1e0d4004344a24c4af966b9d2c83d142e613b0d456ccceb19ae" },
    @{ Title = "текстовый энкодер (8,7 ГБ)"; Remote = "text_encoders/qwen3vl_8b_int8_convrot.safetensors"; Folder = "text_encoders"
       Sha256 = "8bfd0f6e12abf2d2d697ecc888e5e90b0d6741d6708f05799f53afa560452e8f" },
    @{ Title = "VAE (0,6 ГБ)"; Remote = "vae/qwen_image_2.1_vae_bf16.safetensors"; Folder = "vae"
       Sha256 = "bb21f7473051e1ac368515dd3f2e15cd44d7a11748ee8823e1ddca3e4876b7c9" }
)
$WorkflowFile = Join-Path $PSScriptRoot "qwen-image-2.1-uncensored.json"
$GuardFile = Join-Path $PSScriptRoot "vault-guard.ts"
$SevenZipExe = Join-Path $env:ProgramFiles "7-Zip\7z.exe"


# ---------------------------------------------------------------- helpers

function Write-Step([string]$Text) {
    Write-Host ""
    Write-Host "==> $Text" -ForegroundColor Cyan
}
function Write-Ok([string]$Text)   { Write-Host "    [OK] $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "    [!]  $Text" -ForegroundColor Yellow }
function Write-Info([string]$Text) { Write-Host "         $Text" }

function Stop-WithError([string]$Text) {
    Write-Host ""
    Write-Host "ОШИБКА: $Text" -ForegroundColor Red
    Write-Host "Подробный журнал: $LogFile" -ForegroundColor Red
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}

# Windows PowerShell treats native stderr output as an error under "Stop";
# winget/ollama print progress there, so run them with "Continue".
function Invoke-Native([scriptblock]$Command) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { & $Command } finally { $ErrorActionPreference = $previous }
}

function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [Environment]::GetEnvironmentVariable("Path", "User")
}

function Test-Command([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Install-WithWinget([string]$Id, [string]$Title, [scriptblock]$IsInstalled) {
    if (& $IsInstalled) {
        Write-Ok "$Title уже установлен"
        return
    }
    Write-Info "Устанавливаю $Title (может появиться запрос Windows — нажмите «Да»)..."
    Invoke-Native {
        winget install --id $Id -e --silent --accept-package-agreements --accept-source-agreements
    }
    Update-SessionPath
    if (-not (& $IsInstalled)) {
        Stop-WithError "Не удалось установить $Title. Попробуйте вручную: winget install --id $Id"
    }
    Write-Ok "$Title установлен"
}

function Write-FileIfMissing([string]$Path, [string]$Content) {
    if (Test-Path -LiteralPath $Path) { return }
    [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Test-OllamaApi {
    try {
        Invoke-RestMethod -Uri "$OllamaUrl/api/version" -TimeoutSec 3 | Out-Null
        return $true
    } catch {
        return $false
    }
}

# Loads the model with a one-line prompt, then reports how much of it ended up
# in VRAM: anything that spills to system RAM makes answers much slower.
function Test-ModelOnGpu([string]$Model) {
    Write-Info "Проверяю модель $Model (первый запуск ~10–60 секунд)..."
    try {
        $body = @{ model = $Model; prompt = "Скажи одно короткое приветствие по-русски."; stream = $false; think = $false } | ConvertTo-Json
        $reply = Invoke-RestMethod -Uri "$OllamaUrl/api/generate" -Method Post -TimeoutSec 600 `
            -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($body))
        Write-Ok "$Model ответила: $($reply.response.Trim())"

        $loaded = (Invoke-RestMethod -Uri "$OllamaUrl/api/ps").models | Where-Object { $_.name -like "$Model*" } | Select-Object -First 1
        if ($loaded -and $loaded.size -gt 0) {
            $gpuShare = [math]::Round(100 * $loaded.size_vram / $loaded.size)
            if ($gpuShare -ge 95) {
                Write-Ok "$Model работает на видеокарте ($gpuShare%)"
            } else {
                Write-Warn "$Model только на $gpuShare% в видеокарте — будет медленнее. Обновите драйвер NVIDIA и закройте игры/тяжёлые программы."
            }
        }
    } catch {
        Write-Warn "Проверка $Model не прошла: $_"
        Write-Warn "Перезагрузите компьютер и откройте ярлык «Второй мозг (ИИ)»."
    }
}

# Downloads with curl.exe (built into Windows 11): resumes after a broken
# connection and is checked against a pinned SHA-256 before it is used.
function Get-VerifiedFile([string]$Url, [string]$Path, [string]$Sha256, [string]$Title) {
    if (Test-Path -LiteralPath $Path) {
        Write-Info "Проверяю уже скачанный файл: $Title..."
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash -eq $Sha256) {
            Write-Ok "$Title уже скачан"
            return
        }
        Remove-Item -LiteralPath $Path -Force
    }
    $partial = "$Path.part"
    Write-Info "Скачиваю $Title..."
    Invoke-Native { & curl.exe -L --fail --retry 5 --retry-delay 5 -C - -o $partial $Url }
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "Не удалось скачать: $Title. Проверьте интернет и запустите установку снова — скачивание продолжится."
    }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $partial).Hash -ne $Sha256) {
        Remove-Item -LiteralPath $partial -Force
        Stop-WithError "Файл «$Title» скачался с ошибкой. Запустите установку снова."
    }
    Move-Item -Force -LiteralPath $partial -Destination $Path
    Write-Ok "$Title скачан и проверен"
}

# Lists local fixed disks and lets the user pick one by number; Enter picks
# the disk with the most free space. Disks without room for the data (plus the
# programs, on the system disk) are shown but refused.
function Select-InstallDrive([int]$NeededGb, [int]$ProgramsGb) {
    $disks = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | Sort-Object DeviceID)
    if ($disks.Count -le 1) { return $env:SystemDrive }
    $best = $disks | Sort-Object FreeSpace -Descending | Select-Object -First 1
    # No disk fits: return the roomiest one and let the space check explain.
    if (-not ($disks | Where-Object { Test-DriveFits $_ $NeededGb $ProgramsGb })) { return $best.DeviceID }
    Write-Host ""
    Write-Host "    Куда сохранить модели и программу для картинок (нужно ~$NeededGb ГБ)?" -ForegroundColor White
    for ($i = 0; $i -lt $disks.Count; $i++) {
        $d = $disks[$i]
        $free = [math]::Round($d.FreeSpace / 1GB)
        $total = [math]::Round($d.Size / 1GB)
        $label = if ($d.VolumeName) { " ($($d.VolumeName))" } else { "" }
        $mark = if ($d.DeviceID -eq $best.DeviceID) { "   ← больше всего места" } else { "" }
        if (-not (Test-DriveFits $d $NeededGb $ProgramsGb)) { $mark = "   (мало места)" }
        Write-Host ("      {0}) {1}{2}  свободно {3} ГБ из {4} ГБ{5}" -f ($i + 1), $d.DeviceID, $label, $free, $total, $mark)
    }
    for (;;) {
        $answer = Read-Host "    Введите номер диска и нажмите Enter (просто Enter — диск $($best.DeviceID))"
        $n = 0
        $picked = $null
        if (-not $answer.Trim()) {
            $picked = $best
        } elseif ([int]::TryParse($answer.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $disks.Count) {
            $picked = $disks[$n - 1]
        } else {
            Write-Warn "Нет такого номера, попробуйте ещё раз."
            continue
        }
        if (Test-DriveFits $picked $NeededGb $ProgramsGb) { return $picked.DeviceID }
        Write-Warn "На диске $($picked.DeviceID) мало места, выберите другой."
    }
}

function Test-DriveFits($Disk, [int]$NeededGb, [int]$ProgramsGb) {
    $need = $NeededGb
    if ($Disk.DeviceID -eq $env:SystemDrive) { $need += $ProgramsGb }
    return ($Disk.FreeSpace / 1GB) -ge $need
}

function Get-FreeGb([string]$Path) {
    $drive = Get-PSDrive -Name ((Split-Path -Qualifier $Path).TrimEnd(":"))
    return [math]::Round($drive.Free / 1GB)
}

function Restart-Ollama {
    Get-Process -Name "ollama app", "ollama" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    $trayApp = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama app.exe"
    if (Test-Path -LiteralPath $trayApp) {
        Start-Process -FilePath $trayApp
    } else {
        Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
    }
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-OllamaApi) { return }
        Start-Sleep -Seconds 1
    }
    Stop-WithError "Ollama не запустилась. Перезагрузите компьютер и запустите установку ещё раз."
}

# ---------------------------------------------------------------- start

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Magenta
Write-Host "   Установка «Второго мозга»: Oh My Pi + локальный ИИ + Obsidian" -ForegroundColor Magenta
Write-Host "=================================================================" -ForegroundColor Magenta
if ($SkipImages) {
    Write-Host "Это займёт 20–60 минут (в основном скачивание моделей, ~20 ГБ)."
} else {
    Write-Host "Это займёт 40–120 минут (в основном скачивание моделей, ~40 ГБ)."
}
Write-Host "Не закрывайте это окно до сообщения «ГОТОВО»."

# ---------------------------------------------------------------- 1. checks

Write-Step "1/7 Проверяю компьютер"

if (-not (Test-Command "winget")) {
    Stop-WithError "Не найден winget. Откройте Microsoft Store, обновите «Установщик приложений» (App Installer) и запустите установку снова."
}
Write-Ok "winget есть"

if (-not (Test-Path -LiteralPath $GuardFile)) {
    Stop-WithError "Рядом со скриптом нет файла vault-guard.ts. Скопируйте папку установки целиком."
}
if (-not $SkipImages -and -not (Test-Path -LiteralPath $WorkflowFile)) {
    Stop-WithError "Рядом со скриптом нет файла qwen-image-2.1-uncensored.json. Скопируйте папку установки целиком."
}

# Programs (Git, Ollama, Obsidian, omp) always go to the system disk; the
# heavy parts — Ollama models, ComfyUI and its models — go to the chosen one.
$programsGb = 5
$dataGb = 20
if ($SmartModel) { $dataGb += 10 }
if (-not $SkipImages) { $dataGb += 30 }

if (-not $InstallRoot) {
    $drive = Select-InstallDrive $dataGb $programsGb
    if ($drive -ne $env:SystemDrive) { $InstallRoot = "$drive\MyLocalAI" }
}
if ($InstallRoot) {
    if (-not (Test-Path -LiteralPath (Split-Path -Qualifier $InstallRoot))) {
        Stop-WithError "Диск $(Split-Path -Qualifier $InstallRoot) не найден."
    }
    $InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot)
    New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
    $OllamaModelsDir = Join-Path $InstallRoot "ollama-models"
    if (-not $ImagesPath) { $ImagesPath = $InstallRoot }
    if (-not $VaultPath) { $VaultPath = Join-Path $InstallRoot "Второй мозг" }
} else {
    $OllamaModelsDir = ""
    if (-not $ImagesPath) { $ImagesPath = Join-Path $env:SystemDrive "AI" }
}
if (-not $VaultPath) {
    $VaultPath = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "Второй мозг"
}
$ComfyRoot = Join-Path $ImagesPath "ComfyUI_windows_portable"

$dataDrive = Split-Path -Qualifier $(if ($InstallRoot) { $InstallRoot } else { $env:SystemDrive + "\" })
$systemFree = Get-FreeGb ($env:SystemDrive + "\")
if ($dataDrive -eq $env:SystemDrive) {
    if ($systemFree -lt $programsGb + $dataGb) {
        Stop-WithError "На диске $($env:SystemDrive) свободно $systemFree ГБ, а нужно хотя бы $($programsGb + $dataGb) ГБ. Запустите установку снова и выберите другой диск."
    }
    Write-Ok "Всё ставится на диск $($env:SystemDrive) (свободно $systemFree ГБ)"
} else {
    $dataFree = Get-FreeGb $InstallRoot
    if ($dataFree -lt $dataGb) {
        Stop-WithError "На диске $dataDrive свободно $dataFree ГБ, а нужно хотя бы $dataGb ГБ."
    }
    if ($systemFree -lt $programsGb) {
        Stop-WithError "На диске $($env:SystemDrive) свободно $systemFree ГБ, а для программ нужно хотя бы $programsGb ГБ."
    }
    Write-Ok "Модели и картинки: $InstallRoot (свободно $dataFree ГБ)"
    Write-Ok "Программы: диск $($env:SystemDrive) (~$programsGb ГБ, свободно $systemFree ГБ)"
}
Write-Ok "Заметки: $VaultPath"

$ramGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
Write-Ok "Оперативная память: $ramGb ГБ"

$nvidiaSmi = Join-Path $env:SystemRoot "System32\nvidia-smi.exe"
if (Test-Path -LiteralPath $nvidiaSmi) {
    try {
        $gpuLine = (& $nvidiaSmi --query-gpu=name,driver_version,memory.total --format=csv,noheader | Select-Object -First 1)
        $gpu = $gpuLine.Split(",") | ForEach-Object { $_.Trim() }
        Write-Ok "Видеокарта: $($gpu[0]), память $($gpu[2]), драйвер $($gpu[1])"
        $driverMajor = [int]($gpu[1].Split(".")[0])
        if ($driverMajor -lt 570) {
            Write-Warn "Драйвер слишком старый для RTX 50-й серии — модели пойдут на процессор и будут медленными."
            Write-Warn "Обновите драйвер через приложение NVIDIA: https://www.nvidia.com/ru-ru/software/nvidia-app/"
            Write-Warn "Установка продолжится, после обновления драйвера ничего переустанавливать не нужно."
        }
    } catch {
        Write-Warn "Не удалось прочитать данные видеокарты: $_"
    }
} else {
    Write-Warn "Драйвер NVIDIA не найден. Установите его: https://www.nvidia.com/ru-ru/software/nvidia-app/"
    Write-Warn "Без драйвера модели будут работать очень медленно (на процессоре)."
}

# ---------------------------------------------------------------- 2. programs

Write-Step "2/7 Устанавливаю программы"

Install-WithWinget "Git.Git" "Git" {
    (Test-Command "git") -or (Test-Path "C:\Program Files\Git\bin\bash.exe")
}
Install-WithWinget "Ollama.Ollama" "Ollama" {
    (Test-Command "ollama") -or (Test-Path (Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"))
}
Install-WithWinget "Obsidian.Obsidian" "Obsidian" {
    Test-Path -LiteralPath $ObsidianExe
}
if (-not $SkipImages) {
    Install-WithWinget "7zip.7zip" "7-Zip" {
        Test-Path -LiteralPath $SevenZipExe
    }
    # PyTorch in ComfyUI needs the Visual C++ runtime (otherwise: c10.dll error).
    Install-WithWinget "Microsoft.VCRedist.2015+.x64" "Visual C++ Runtime" {
        $vc = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64" -ErrorAction SilentlyContinue
        [bool]($vc -and $vc.Installed -eq 1)
    }
}

# ---------------------------------------------------------------- 3. ollama

Write-Step "3/7 Настраиваю локальные модели (Ollama)"

# Context large enough for an agent's instructions; flash attention and an
# 8-bit KV cache keep it inside 12 GB of VRAM. OLLAMA_CONTEXT_LENGTH is read
# by both Ollama and omp.
$ollamaEnv = [ordered]@{
    "OLLAMA_CONTEXT_LENGTH"  = "$ContextLength"
    "OLLAMA_FLASH_ATTENTION" = "1"
    "OLLAMA_KV_CACHE_TYPE"   = "q8_0"
    "OLLAMA_KEEP_ALIVE"      = "30m"
}
if ($OllamaModelsDir) {
    New-Item -ItemType Directory -Force -Path $OllamaModelsDir | Out-Null
    $ollamaEnv["OLLAMA_MODELS"] = $OllamaModelsDir
}
foreach ($name in $ollamaEnv.Keys) {
    [Environment]::SetEnvironmentVariable($name, $ollamaEnv[$name], "User")
    Set-Item -Path "Env:$name" -Value $ollamaEnv[$name]
}
Write-Ok "Контекст $ContextLength токенов, экономный режим памяти"
if ($OllamaModelsDir) { Write-Ok "Модели Ollama хранятся в $OllamaModelsDir" }

Restart-Ollama
Write-Ok "Ollama запущена"

if ($SkipModels) {
    Write-Warn "Скачивание моделей пропущено (-SkipModels)"
} else {
    foreach ($model in @($MainModel, $FastModel)) {
        Write-Info "Скачиваю модель $model (прогресс ниже)..."
        Invoke-Native { ollama pull $model }
        if ($LASTEXITCODE -ne 0) {
            Stop-WithError "Не удалось скачать $model. Проверьте интернет и запустите установку снова — скачивание продолжится."
        }
        Write-Ok "Модель $model готова"
    }
}

# The smart model is optional: a failed download leaves the main setup working.
$smartReady = $false
if ($SmartModel -and -not $SkipModels) {
    Write-Info "Скачиваю модель для «умного режима» $SmartModel (~8 ГБ)..."
    Invoke-Native { ollama pull $SmartModel }
    if ($LASTEXITCODE -eq 0) {
        $smartReady = $true
        Write-Ok "Модель $SmartModel готова"
    } else {
        Write-Warn "Не удалось скачать $SmartModel — «умный режим» пропущен, остальное работает."
        Write-Warn "Позже можно докачать: запустите УСТАНОВИТЬ.cmd ещё раз."
    }
}

# ---------------------------------------------------------------- 4. omp

Write-Step "4/7 Устанавливаю Oh My Pi (omp)"

if (Test-Path -LiteralPath $OmpExe) {
    Write-Ok "omp уже установлен, проверяю обновление..."
}
# The official installer verifies the binary's SHA-256 and adds omp to PATH.
try {
    & ([scriptblock]::Create((Invoke-RestMethod -Uri "https://omp.sh/install.ps1"))) -Binary
} catch {
    Stop-WithError "Официальный установщик omp завершился с ошибкой: $_"
}
Update-SessionPath
if (-not (Test-Path -LiteralPath $OmpExe)) {
    Stop-WithError "omp не установился (нет файла $OmpExe)."
}
$ompVersion = Invoke-Native { & $OmpExe --version }
Write-Ok "omp: $ompVersion"

$agentDir = Join-Path $env:USERPROFILE ".omp\agent"
New-Item -ItemType Directory -Force -Path $agentDir | Out-Null
$configFile = Join-Path $agentDir "config.yml"
if (Test-Path -LiteralPath $configFile) {
    $backup = "$configFile.bak-" + (Get-Date -Format "yyyyMMdd-HHmmss")
    Copy-Item -LiteralPath $configFile -Destination $backup
    Write-Info "Старые настройки omp сохранены в $backup"
}
$config = @'
# Настроено установщиком «Второго мозга».
# default — основная модель, smol — быстрая для простых задач.
modelRoles:
  default: ollama/__MAIN__
  smol: ollama/__FAST__

# Помощник работает только с заметками. Главная защита — хук
# hooks/pre/vault-guard.ts (блокирует всё за пределами папки заметок);
# настройки ниже вдобавок убирают лишние инструменты, чтобы модель
# их даже не видела.
bash:
  enabled: false
eval:
  py: false
  js: false
browser:
  enabled: false
lsp:
  enabled: false
async:
  enabled: false
tools:
  approval:
    bash: deny
    eval: deny
    task: deny
    browser: deny
    computer: deny
    debug: deny
    ida: deny
    github: deny
    lsp: deny
    ast_grep: deny
    ast_edit: deny
    security_scan: deny
    manage_skill: deny
    checkpoint: deny
    rewind: deny
# Не подхватывать настройки, MCP-серверы и хуки других ИИ-программ.
disabledProviders:
  - claude
  - claude-plugins
  - claude-md
  - codex
  - gemini
  - github
  - opencode
  - cursor
  - windsurf
  - cline
  - vscode
  - agents
  - agents-md
  - agent-plugins
  - omp-plugins
  - mcp-json
  - ssh-json
  - custom-context
'@
$config = $config.Replace("__MAIN__", $MainModel).Replace("__FAST__", $FastModel)
[System.IO.File]::WriteAllText($configFile, $config, $Utf8NoBom)
Write-Ok "omp подключён к локальным моделям ($MainModel, $FastModel)"

# The guard lives in the user agent folder, outside the vault, so the agent
# cannot rewrite it. The vault path is baked in as a JSON string literal.
$hookDir = Join-Path $agentDir "hooks\pre"
New-Item -ItemType Directory -Force -Path $hookDir | Out-Null
$vaultLiteral = ConvertTo-Json -InputObject ([string]$VaultPath) -Compress
$guard = (Get-Content -LiteralPath $GuardFile -Raw -Encoding UTF8).Replace("__VAULT__", $vaultLiteral)
[System.IO.File]::WriteAllText((Join-Path $hookDir "vault-guard.ts"), $guard, $Utf8NoBom)
Write-Ok "Помощник ограничен папкой заметок: $VaultPath"

# ---------------------------------------------------------------- 5. vault

Write-Step "5/7 Создаю хранилище заметок «Второй мозг»"

$folders = @("0 Входящие", "1 Проекты", "2 Сферы жизни", "3 Знания", "4 Архив", "Дневник", "Шаблоны", ".omp")
foreach ($folder in $folders) {
    New-Item -ItemType Directory -Force -Path (Join-Path $VaultPath $folder) | Out-Null
}

$agentsMd = @'
# Ты — помощник «Второй мозг»

Эта папка — личная база заметок пользователя (хранилище Obsidian).
Пользователь не программист и не разбирается в ИИ. Общайся по-русски, просто и коротко,
без технических терминов. Если просьба непонятна — задай один уточняющий вопрос.

## Как устроены заметки

- `0 Входящие/` — всё новое и неразобранное: быстрые мысли, ссылки, идеи.
- `1 Проекты/` — дела с целью и сроком («Ремонт кухни», «Отпуск в мае»).
- `2 Сферы жизни/` — постоянные темы без срока («Здоровье», «Финансы», «Семья», «Работа»).
- `3 Знания/` — полезные сведения: конспекты, инструкции, рецепты, выжимки из статей.
- `4 Архив/` — завершённые проекты и неактуальное.
- `Дневник/` — заметки по дням, имя файла `ГГГГ-ММ-ДД.md`.
- `Шаблоны/` — заготовки заметок.

## Правила оформления

- Каждая заметка — отдельный файл `.md` с понятным русским названием, например `Ремонт кухни.md`.
- В начале заметки блок свойств:
  ```
  ---
  создано: ГГГГ-ММ-ДД
  теги: [тема1, тема2]
  ---
  ```
- Связывай заметки ссылками Obsidian: `[[Название заметки]]`.
- Пиши кратко: заголовки, списки, задачи в виде `- [ ] дело`.

## Что ты умеешь делать по просьбе

- «Запиши…» — создай заметку во `0 Входящие/` (или сразу в подходящую папку, если она очевидна).
- «Разбери входящие» — разложи заметки из `0 Входящие/` по папкам, добавь теги и ссылки.
  Сначала покажи план, перенос делай после согласия.
- «Что я знаю про…» / «Найди…» — поищи по всем заметкам и ответь со ссылками на них.
- «Дневник» — открой или создай заметку на сегодня в `Дневник/`.
- «Итоги недели» — собери выжимку из дневника и проектов за последние 7 дней.

## Чего нельзя

- Никогда не удаляй заметки и не перезаписывай их целиком без явного «да» от пользователя.
- Не трогай папки `.obsidian/` и `.omp/`.
- Работай только внутри этой папки: не запускай программы и не меняй файлы за её пределами.
- Доступ и так ограничен: файлы вне этой папки, команды и запуск программ заблокированы.
  Если действие заблокировано — не ищи обходных путей, а коротко объясни пользователю, что это недоступно.
- Не выдумывай факты о пользователе: если чего-то нет в заметках — так и скажи.
'@
Write-FileIfMissing (Join-Path $VaultPath ".omp\AGENTS.md") $agentsMd

$welcome = @'
# Добро пожаловать во «Второй мозг»

Здесь хранятся ваши заметки. Это обычные текстовые файлы на вашем компьютере —
в интернет они не отправляются, ИИ работает прямо на вашей видеокарте.

## Как пользоваться

1. На рабочем столе откройте ярлык **«Второй мозг (ИИ)»** — появится окно для разговора с помощником.
2. Пишите обычным языком, например:
   - «Запиши: позвонить маме в субботу»
   - «Создай проект "Отпуск в мае" и список дел для него»
   - «Что у меня есть про финансы?»
   - «Разбери входящие»
3. Ярлык **«Заметки (Obsidian)»** открывает эти же заметки для чтения и правки.

## Папки

- **0 Входящие** — всё новое
- **1 Проекты** — дела со сроком
- **2 Сферы жизни** — постоянные темы
- **3 Знания** — полезные сведения
- **4 Архив** — завершённое
- **Дневник** — записи по дням
'@
Write-FileIfMissing (Join-Path $VaultPath "Добро пожаловать.md") $welcome

$dailyTemplate = @'
---
создано: {{date}}
теги: [дневник]
---
# {{date}}

## Главное сегодня
- [ ]

## Заметки

## Итог дня
'@
Write-FileIfMissing (Join-Path $VaultPath "Шаблоны\Дневник.md") $dailyTemplate
Write-Ok "Хранилище: $VaultPath"

# Register the vault with Obsidian so it opens straight into it. Obsidian
# rewrites this file while running, so only touch it when Obsidian is closed.
try {
    $obsidianRunning = Get-Process -Name "Obsidian" -ErrorAction SilentlyContinue
    $obsidianJson = Join-Path $env:APPDATA "obsidian\obsidian.json"
    if (-not $obsidianRunning) {
        $state = $null
        if (Test-Path -LiteralPath $obsidianJson) {
            $state = Get-Content -LiteralPath $obsidianJson -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        if (-not $state) { $state = [pscustomobject]@{} }
        if (-not $state.PSObject.Properties["vaults"]) {
            $state | Add-Member -NotePropertyName "vaults" -NotePropertyValue ([pscustomobject]@{})
        }
        $known = $state.vaults.PSObject.Properties | Where-Object { $_.Value.path -eq $VaultPath }
        if (-not $known) {
            $id = -join ((1..16) | ForEach-Object { "{0:x}" -f (Get-Random -Maximum 16) })
            $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $state.vaults | Add-Member -NotePropertyName $id -NotePropertyValue ([pscustomobject]@{ path = $VaultPath; ts = $ts; open = $true })
            New-Item -ItemType Directory -Force -Path (Split-Path $obsidianJson) | Out-Null
            [System.IO.File]::WriteAllText($obsidianJson, ($state | ConvertTo-Json -Depth 10 -Compress), $Utf8NoBom)
        }
        Write-Ok "Obsidian будет сразу открывать «Второй мозг»"
    } else {
        Write-Warn "Obsidian открыт — в нём выберите «Открыть папку как хранилище» и укажите $VaultPath"
    }
} catch {
    Write-Warn "Не удалось подключить хранилище к Obsidian автоматически: $_"
    Write-Warn "В Obsidian выберите «Открыть папку как хранилище» и укажите $VaultPath"
}

# ---------------------------------------------------------------- 6. images

Write-Step "6/7 Генерация картинок (ComfyUI + Qwen-Image 2.1 Uncensored)"

$imagesReady = $false
if ($SkipImages) {
    Write-Warn "Генерация картинок пропущена (-SkipImages)"
} else {
    if ($ramGb -lt 32) {
        Write-Warn "Оперативной памяти $ramGb ГБ — для картинок желательно 32 ГБ. Работать будет, но медленно."
    }
    New-Item -ItemType Directory -Force -Path $ImagesPath | Out-Null

    $comfyMain = Join-Path $ComfyRoot "ComfyUI\main.py"
    if (Test-Path -LiteralPath $comfyMain) {
        Write-Ok "ComfyUI уже установлен: $ComfyRoot"
    } else {
        $archive = Join-Path $ImagesPath "ComfyUI_windows_portable_nvidia.7z"
        Get-VerifiedFile $ComfyArchiveUrl $archive $ComfyArchiveSha256 "ComfyUI $ComfyVersion (2 ГБ)"
        Write-Info "Распаковываю ComfyUI (несколько минут)..."
        Invoke-Native { & $SevenZipExe x $archive "-o$ImagesPath" -y | Out-Null }
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $comfyMain)) {
            Stop-WithError "Не удалось распаковать ComfyUI в $ImagesPath."
        }
        Remove-Item -LiteralPath $archive -Force
        Write-Ok "ComfyUI установлен: $ComfyRoot"
    }

    foreach ($file in $ImageFiles) {
        $folder = Join-Path $ComfyRoot ("ComfyUI\models\" + $file.Folder)
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        $target = Join-Path $folder (Split-Path $file.Remote -Leaf)
        Get-VerifiedFile "$ImageRepo/$($file.Remote)?download=true" $target $file.Sha256 $file.Title
    }

    $workflowDir = Join-Path $ComfyRoot "ComfyUI\user\default\workflows"
    New-Item -ItemType Directory -Force -Path $workflowDir | Out-Null
    Copy-Item -Force -LiteralPath $WorkflowFile -Destination (Join-Path $workflowDir "Qwen-Image uncensored.json")
    Write-Ok "Готовый сценарий «Qwen-Image uncensored» добавлен в ComfyUI"

    # The assistant's models stay in VRAM for 30 minutes; free the card before
    # ComfyUI starts, or both will crawl.
    $launcher = Join-Path $ImagesPath "start-comfyui.ps1"
    $launcherText = @'
# Frees the GPU from Ollama's models, then starts ComfyUI (it opens the browser).
try {
    $loaded = (Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/ps" -TimeoutSec 3).models
    foreach ($m in $loaded) { & ollama stop $m.name }
} catch { }
Set-Location -LiteralPath "__ROOT__"
& .\python_embeded\python.exe -s ComfyUI\main.py --windows-standalone-build
'@
    [System.IO.File]::WriteAllText($launcher, $launcherText.Replace("__ROOT__", $ComfyRoot), (New-Object System.Text.UTF8Encoding $true))

    $desktop = [Environment]::GetFolderPath("Desktop")
    $shell = New-Object -ComObject WScript.Shell
    $images = $shell.CreateShortcut((Join-Path $desktop "Картинки (ComfyUI).lnk"))
    $images.TargetPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $images.Arguments = "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$launcher`""
    $images.WorkingDirectory = $ComfyRoot
    $images.IconLocation = (Join-Path $ComfyRoot "python_embeded\python.exe") + ",0"
    $images.Description = "Генерация картинок Qwen-Image 2.1 (откроется в браузере)"
    $images.Save()
    Write-Ok "Ярлык «Картинки (ComfyUI)» на рабочем столе"

    Write-Info "Проверяю, что ComfyUI видит видеокарту..."
    $torchCheck = Invoke-Native {
        & (Join-Path $ComfyRoot "python_embeded\python.exe") -c "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0) if torch.cuda.is_available() else '')" 2>&1
    }
    if ("$torchCheck" -match "^True") {
        $imagesReady = $true
        Write-Ok "ComfyUI работает на видеокарте: $(("$torchCheck" -replace '^True\s*', '').Trim())"
    } else {
        Write-Warn "ComfyUI не видит видеокарту: $torchCheck"
        Write-Warn "Обновите драйвер NVIDIA и перезагрузите компьютер."
    }
}

# ---------------------------------------------------------------- 7. shortcuts + test

Write-Step "7/7 Ярлыки и проверка"

$desktop = [Environment]::GetFolderPath("Desktop")
$shell = New-Object -ComObject WScript.Shell

$brain = $shell.CreateShortcut((Join-Path $desktop "Второй мозг (ИИ).lnk"))
$brain.TargetPath = Join-Path $env:SystemRoot "System32\cmd.exe"
$brain.Arguments = "/k cd /d `"$VaultPath`" && `"$OmpExe`""
$brain.WorkingDirectory = $VaultPath
$brain.IconLocation = "$OmpExe,0"
$brain.Description = "Помощник с локальным ИИ для ваших заметок"
$brain.Save()

$smartShortcut = Join-Path $desktop "Второй мозг — умный режим (ИИ).lnk"
if ($smartReady) {
    $smart = $shell.CreateShortcut($smartShortcut)
    $smart.TargetPath = Join-Path $env:SystemRoot "System32\cmd.exe"
    $smart.Arguments = "/k cd /d `"$VaultPath`" && `"$OmpExe`" --model ollama/$SmartModel"
    $smart.WorkingDirectory = $VaultPath
    $smart.IconLocation = "$OmpExe,0"
    $smart.Description = "Помощник на большой модели ${SmartModel}: умнее, но медленнее"
    $smart.Save()
    Write-Ok "Ярлык «Второй мозг — умный режим (ИИ)» на рабочем столе"
}

$notes = $shell.CreateShortcut((Join-Path $desktop "Заметки (Obsidian).lnk"))
$notes.TargetPath = $ObsidianExe
$notes.WorkingDirectory = Split-Path $ObsidianExe
$notes.Save()
Write-Ok "Ярлыки «Второй мозг (ИИ)» и «Заметки (Obsidian)» на рабочем столе"

if (-not $SkipModels) {
    Test-ModelOnGpu $MainModel
}
if ($smartReady) {
    Test-ModelOnGpu $SmartModel
}

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Green
Write-Host "   ГОТОВО!" -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Green
Write-Host "Откройте на рабочем столе ярлык «Второй мозг (ИИ)» и напишите, например:"
Write-Host "    Запиши: купить подарок Ане до пятницы" -ForegroundColor White
if ($smartReady) {
    Write-Host "Для сложных вопросов есть ярлык «Второй мозг — умный режим (ИИ)» — умнее, но отвечает медленнее."
}
Write-Host "Заметки появятся в папке: $VaultPath"
if ($imagesReady) {
    Write-Host "Картинки: ярлык «Картинки (ComfyUI)» → слева «Рабочие процессы» → «Qwen-Image uncensored»."
    Write-Host "Готовые картинки сохраняются в: $(Join-Path $ComfyRoot 'ComfyUI\output')"
}
if ($OllamaModelsDir) {
    Write-Host "Модели ИИ лежат в: $OllamaModelsDir"
}
Write-Host "Журнал установки: $LogFile"

try { Stop-Transcript | Out-Null } catch { }
