# =====================================================================
#  "Второй мозг" на Windows 11: Oh My Pi + локальные модели + Obsidian
#
#  Что делает скрипт (можно запускать повторно — уже сделанное пропускается):
#    1. Проверяет видеокарту NVIDIA и драйвер
#    2. Ставит Git (нужен omp для команд), Ollama (локальные модели), Obsidian (заметки)
#    3. Настраивает Ollama под 12 ГБ видеопамяти и скачивает модели:
#       qwen3.5:9b (основная), qwen3.5:4b (быстрая), bonsai-2:27b («умный режим»),
#       Qwen3.8 27B abliterated («без цензуры»)
#    4. Ставит Oh My Pi (omp) и окно OMP Desktop, подключает omp к локальным моделям и запирает
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
#    -UncensoredModel ""       не ставить модель «без цензуры»
#    -SkipImages               не ставить генерацию картинок (~20 ГБ)
#    -SkipDesktop              не ставить окно OMP Desktop (останется только терминал)
#    -ImagesPath "D:\AI"       куда ставить ComfyUI (по умолчанию — папка установки)
# =====================================================================

param(
    [string]$VaultPath = "",
    [string]$MainModel = "qwen3.5:9b",
    [string]$FastModel = "qwen3.5:4b",
    [string]$SmartModel = "bonsai-2:27b",
    [string]$UncensoredModel = "hf.co/huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF:UD-IQ2_S",
    [int]$ContextLength = 32768,
    [switch]$SkipModels,
    [switch]$SkipImages,
    [switch]$SkipDesktop,
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
# Plain .cmd launchers live here; desktop shortcuts point at them without
# arguments, which antivirus heuristics flag far less than cmd.exe /k ... links.
$LaunchersDir = Join-Path $env:LOCALAPPDATA "MyLocalAI"

# The uncensored GGUF on Hugging Face ships no chat template, so Ollama would
# not format tool calls; it is rebuilt under this name with the renderer and
# parser of the official qwen3.8 model (needs Ollama 0.32.12+).
$UncensoredName = "qwen3.8-uncensored:27b"
# bonsai-2 (the smart model) needs the newest of the default models.
$MinOllama = [version]"0.40.6"

# Models are pulled only from Hugging Face: Ollama's own library serves its
# files from Cloudflare R2, which some networks cannot reach. Each one is
# re-created under its usual Ollama name with the official library model's
# renderer, parser and sampling parameters, so tool calls work the same.
$HfMirrors = @{
    "qwen3.5:9b"   = @{ Source = "hf.co/unsloth/Qwen3.5-9B-GGUF:Q4_K_M"
                        Renderer = "qwen3.5"; Parser = "qwen3.5"
                        Params = [ordered]@{ presence_penalty = 1.5; temperature = 1; top_k = 20; top_p = 0.95 } }
    "qwen3.5:4b"   = @{ Source = "hf.co/unsloth/Qwen3.5-4B-GGUF:Q4_K_M"
                        Renderer = "qwen3.5"; Parser = "qwen3.5"
                        Params = [ordered]@{ presence_penalty = 1.5; temperature = 1; top_k = 20; top_p = 0.95 } }
    "gemma4:12b"   = @{ Source = "hf.co/unsloth/gemma-4-12b-it-GGUF:Q4_K_M"
                        Renderer = "gemma4"; Parser = "gemma4"
                        Params = [ordered]@{ temperature = 1; top_k = 64; top_p = 0.95 } }
    "bonsai-2:4b"  = @{ Source = "hf.co/prism-ml/Ternary-Bonsai-2-4B-gguf:Ternary-Bonsai-2-4B-Q2_0"
                        Renderer = "qwen3.5"; Parser = "qwen3.5"
                        Params = [ordered]@{ presence_penalty = 1; temperature = 1; top_k = 20; top_p = 0.95 } }
    "bonsai-2:9b"  = @{ Source = "hf.co/prism-ml/Ternary-Bonsai-2-9B-gguf:Ternary-Bonsai-2-9B-Q2_0"
                        Renderer = "qwen3.5"; Parser = "qwen3.5"
                        Params = [ordered]@{ presence_penalty = 1; temperature = 1; top_k = 20; top_p = 0.95 } }
    "bonsai-2:27b" = @{ Source = "hf.co/prism-ml/Ternary-Bonsai-2-27B-gguf:Ternary-Bonsai-2-27B-Q2_0"
                        Renderer = "qwen3.8"; Parser = "qwen3.5"
                        Params = [ordered]@{ min_p = 0.05; temperature = 1; top_k = 20; top_p = 0.95 } }
}
$UncensoredMinOllama = [version]"0.32.12"

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

function Get-OllamaVersion {
    try {
        $raw = (Invoke-RestMethod -Uri "$OllamaUrl/api/version" -TimeoutSec 5).version
        return [version](($raw -split "[-+]")[0])
    } catch {
        return $null
    }
}

# Pulls `$Source` (an hf.co/... reference), re-creates it as `$Name` with the
# given renderer, parser and parameters, and drops the hf.co tag (the weights
# stay, shared by the new name). Returns $true on success.
function New-OllamaModelFromHf([string]$Name, [string]$Source, [string]$Renderer, [string]$Parser, $Params) {
    Invoke-Native { ollama pull $Source }
    if ($LASTEXITCODE -ne 0) { return $false }
    $lines = @("FROM $Source", "RENDERER $Renderer", "PARSER $Parser")
    foreach ($key in $Params.Keys) {
        $lines += "PARAMETER $key " + ([string]$Params[$key]).Replace(",", ".")
    }
    $modelfile = Join-Path $env:TEMP ("ollama-" + ($Name -replace "[^A-Za-z0-9.-]", "_") + ".Modelfile")
    [System.IO.File]::WriteAllLines($modelfile, [string[]]$lines, $Utf8NoBom)
    Invoke-Native { ollama create $Name -f $modelfile }
    $created = $LASTEXITCODE -eq 0
    Remove-Item -LiteralPath $modelfile -Force -ErrorAction SilentlyContinue
    if ($created) { Invoke-Native { ollama rm $Source | Out-Null } }
    return $created
}

# Gets a model from Hugging Face: a name from $HfMirrors is re-created under
# that name; an explicit hf.co/... reference is pulled as is. Returns $true on
# success.
function Install-OllamaModel([string]$Name) {
    if ($Name -like "hf.co/*") {
        Invoke-Native { ollama pull $Name }
        return $LASTEXITCODE -eq 0
    }
    $mirror = $HfMirrors[$Name]
    if (-not $mirror) {
        Write-Warn "Для модели $Name нет источника на Hugging Face. Доступны: $(($HfMirrors.Keys | Sort-Object) -join ', ') или ссылка вида hf.co/автор/репозиторий:файл."
        return $false
    }
    return New-OllamaModelFromHf $Name $mirror.Source $mirror.Renderer $mirror.Parser $mirror.Params
}

# Writes "$LaunchersDir\$Title.cmd" running `$Commands`, then a desktop
# shortcut to it. If the shortcut cannot be saved (some antivirus products
# block it), the .cmd itself is copied to the desktop instead; setup goes on.
function New-Launcher([string]$Title, [string[]]$Commands, [string]$Description, [string]$Icon = "") {
    New-Item -ItemType Directory -Force -Path $LaunchersDir | Out-Null
    $cmdPath = Join-Path $LaunchersDir "$Title.cmd"
    $body = @("@echo off", "chcp 65001 >nul") + $Commands
    [System.IO.File]::WriteAllText($cmdPath, (($body -join "`r`n") + "`r`n"), $Utf8NoBom)
    New-DesktopShortcut $Title $cmdPath $LaunchersDir $Description $Icon -FallbackCopy $cmdPath
}

function New-DesktopShortcut([string]$Title, [string]$Target, [string]$WorkDir, [string]$Description, [string]$Icon = "", [string]$FallbackCopy = "") {
    $desktop = [Environment]::GetFolderPath("Desktop")
    New-Item -ItemType Directory -Force -Path $desktop | Out-Null
    $lnkPath = Join-Path $desktop "$Title.lnk"
    try {
        $link = (New-Object -ComObject WScript.Shell).CreateShortcut($lnkPath)
        $link.TargetPath = $Target
        $link.WorkingDirectory = $WorkDir
        if ($Icon) { $link.IconLocation = $Icon }
        $link.Description = $Description
        $link.Save()
    } catch {
        Write-Warn "Ярлык «$Title» не сохранился: $($_.Exception.Message)"
    }
    if (Test-Path -LiteralPath $lnkPath) {
        Write-Ok "Ярлык «$Title» на рабочем столе"
        return
    }
    if ($FallbackCopy) {
        try {
            Copy-Item -LiteralPath $FallbackCopy -Destination (Join-Path $desktop "$Title.cmd") -Force
            Write-Warn "Вместо ярлыка положил на рабочий стол файл «$Title.cmd» — он работает так же."
            return
        } catch { }
    }
    Write-Warn "Не удалось создать ярлык «$Title» (возможно, мешает антивирус). Запускайте: $Target"
}

# A path quoted for a .cmd line. Inside a batch file `%` starts a variable
# reference even within quotes, so it is doubled; `"` cannot occur in paths.
function ConvertTo-CmdArg([string]$Value) {
    return '"' + $Value.Replace('%', '%%') + '"'
}

# Lines for a launcher that opens the assistant in the vault, optionally on a
# given model; the window stays open if omp exits with an error.
function Get-AssistantCommands([string]$ModelArg = "") {
    $run = ConvertTo-CmdArg $OmpExe
    if ($ModelArg) { $run += " --model $ModelArg" }
    return @("cd /d $(ConvertTo-CmdArg $VaultPath)", $run, "if errorlevel 1 pause")
}

# Path of OMP Desktop's main .exe from its uninstall entry (per-user or
# machine-wide), or "" when it is not installed. Read from the registry rather
# than guessed: the binary name depends on the Tauri version that built it.
function Find-OmpDesktop {
    $roots = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*")
    foreach ($entry in Get-ItemProperty -Path $roots -ErrorAction SilentlyContinue) {
        if ($entry.DisplayName -notlike "OMP Desktop*") { continue }
        $icon = ("$($entry.DisplayIcon)" -replace ",\s*-?\d+$", "").Trim().Trim('"')
        if ($icon -like "*.exe" -and (Test-Path -LiteralPath $icon)) { return $icon }
        $dir = "$($entry.InstallLocation)".Trim('"')
        if ($dir -and (Test-Path -LiteralPath $dir)) {
            $exe = Get-ChildItem -LiteralPath $dir -Filter *.exe -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch "uninstall" } | Select-Object -First 1
            if ($exe) { return $exe.FullName }
        }
    }
    return ""
}

function Restart-Ollama {
    Get-Process -Name "ollama app", "ollama" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    $trayApp = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama app.exe"
    if (Test-Path -LiteralPath $trayApp) {
        Start-Process -FilePath $trayApp
    } else {
        Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Minimized
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
    Write-Host "Это займёт 20–60 минут (в основном скачивание моделей, ~30 ГБ)."
} else {
    Write-Host "Это займёт 40–120 минут (в основном скачивание моделей, ~50 ГБ)."
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

$ramGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
Write-Ok "Оперативная память: $ramGb ГБ"

# ComfyUI portable ships PyTorch built for CUDA 13.0, which needs driver 580+.
# Ollama alone runs on older drivers, so an old driver is a warning, not a stop.
$MinDriver = 580
$vramGb = 0
$nvidiaSmi = Join-Path $env:SystemRoot "System32\nvidia-smi.exe"
if (Test-Path -LiteralPath $nvidiaSmi) {
    try {
        $gpuLine = (& $nvidiaSmi --query-gpu=name,driver_version,memory.total --format=csv,noheader,nounits | Select-Object -First 1)
        $gpu = $gpuLine.Split(",") | ForEach-Object { $_.Trim() }
        $vramGb = [math]::Round([double]$gpu[2] / 1024, 1)
        Write-Ok "Видеокарта: $($gpu[0]), память $vramGb ГБ, драйвер $($gpu[1])"
        $driverMajor = [int]($gpu[1].Split(".")[0])
        if ($driverMajor -lt $MinDriver) {
            Write-Warn "Драйвер $($gpu[1]) устарел: нужен $MinDriver или новее, иначе программа для картинок не запустится."
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

# Defaults target 12 GB cards (RTX 3060 12 GB, 4070, 5070, …). Smaller cards
# get lighter defaults; anything passed explicitly on the command line wins.
if ($vramGb -gt 0 -and $vramGb -lt 11) {
    Write-Warn "Видеопамяти $vramGb ГБ — включаю облегчённый режим (рассчитано на 12 ГБ):"
    if (-not $PSBoundParameters.ContainsKey("MainModel")) { $MainModel = "qwen3.5:4b" }
    if (-not $PSBoundParameters.ContainsKey("SmartModel")) { $SmartModel = "" }
    if (-not $PSBoundParameters.ContainsKey("UncensoredModel")) { $UncensoredModel = "" }
    Write-Warn "  основная модель $MainModel, «умный режим» и модель «без цензуры» не ставятся."
    if ($vramGb -lt 7) {
        if (-not $PSBoundParameters.ContainsKey("SkipImages")) { $SkipImages = $true }
        if ($SkipImages) { Write-Warn "  генерация картинок не ставится: ей нужно хотя бы 8 ГБ видеопамяти." }
    } elseif (-not $SkipImages) {
        Write-Warn "  картинки будут рисоваться заметно медленнее: модель не помещается в видеопамять целиком."
    }
}

# Programs (Git, Ollama, Obsidian, omp) always go to the system disk; the
# heavy parts — Ollama models, ComfyUI and its models — go to the chosen one.
$programsGb = 5
$dataGb = 20
if ($SmartModel) { $dataGb += 10 }
if ($UncensoredModel) { $dataGb += 10 }
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

# An Ollama installed earlier is left alone by winget install, and an old one
# refuses newer models ("requires a newer version"), so upgrade it first.
$ollamaVersion = Get-OllamaVersion
if ($ollamaVersion -and $ollamaVersion -lt $MinOllama) {
    Write-Info "Ollama $ollamaVersion устарела (нужна $MinOllama+), обновляю..."
    Invoke-Native {
        winget upgrade --id Ollama.Ollama -e --silent --accept-package-agreements --accept-source-agreements
    }
    Update-SessionPath
    Restart-Ollama
    $ollamaVersion = Get-OllamaVersion
}
if ($ollamaVersion -and $ollamaVersion -lt $MinOllama) {
    Stop-WithError "Ollama $ollamaVersion слишком старая, а обновить её не получилось. Скачайте свежую с https://ollama.com/download, установите и запустите УСТАНОВИТЬ.cmd ещё раз."
}
if ($ollamaVersion) { Write-Ok "Ollama $ollamaVersion" }

if ($SkipModels) {
    Write-Warn "Скачивание моделей пропущено (-SkipModels)"
} else {
    foreach ($model in @($MainModel, $FastModel)) {
        Write-Info "Скачиваю модель $model с Hugging Face (прогресс ниже)..."
        if (-not (Install-OllamaModel $model)) {
            Stop-WithError "Не удалось скачать $model. Проверьте интернет (если сайты блокируются — включите VPN) и запустите установку снова — скачивание продолжится."
        }
        Write-Ok "Модель $model готова"
    }
}

# The smart model is optional: a failed download leaves the main setup working.
$smartReady = $false
if ($SmartModel -and -not $SkipModels) {
    Write-Info "Скачиваю модель для «умного режима» $SmartModel с Hugging Face (~8 ГБ)..."
    if (Install-OllamaModel $SmartModel) {
        $smartReady = $true
        Write-Ok "Модель $SmartModel готова"
    } else {
        Write-Warn "Не удалось скачать $SmartModel — «умный режим» пропущен, остальное работает."
        Write-Warn "Позже можно докачать: запустите УСТАНОВИТЬ.cmd ещё раз."
    }
}

# Optional as well. Pulled from Hugging Face, then re-created under a short
# name with a Modelfile that adds the chat template; the hf.co tag is removed
# afterwards (the weights stay, shared by the new name).
$uncensoredReady = $false
if ($UncensoredModel -and -not $SkipModels) {
    $ollamaVersion = Get-OllamaVersion
    if ($ollamaVersion -and $ollamaVersion -lt $UncensoredMinOllama) {
        Write-Warn "Ollama $ollamaVersion слишком старая для модели «без цензуры» (нужна $UncensoredMinOllama+) — пропускаю."
        Write-Warn "Обновите Ollama (winget upgrade Ollama.Ollama) и запустите УСТАНОВИТЬ.cmd ещё раз."
    } else {
        Write-Info "Скачиваю модель «без цензуры» Qwen3.8 27B (~9 ГБ)..."
        $params = [ordered]@{ temperature = 1; top_k = 20; top_p = 0.95; min_p = 0 }
        if (New-OllamaModelFromHf $UncensoredName $UncensoredModel "qwen3.8" "qwen3.5" $params) {
            $uncensoredReady = $true
            Write-Ok "Модель «без цензуры» готова: $UncensoredName"
        } else {
            Write-Warn "Не удалось скачать модель «без цензуры» — пропускаю, остальное работает."
            Write-Warn "Позже можно докачать: запустите УСТАНОВИТЬ.cmd ещё раз."
        }
    }
}

# ---------------------------------------------------------------- 4. omp

Write-Step "4/7 Устанавливаю Oh My Pi (omp)"

# omp's own installer downloads from Cloudflare R2, which some networks cannot
# reach; the same binary is attached to GitHub releases with a SHA-256 digest.
$ompAssetName = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "omp-windows-arm64.exe" } else { "omp-windows-x64.exe" }
try {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/can1357/oh-my-pi/releases/latest" -Headers @{ "User-Agent" = "MyLocalAI-setup" } -TimeoutSec 60
} catch {
    Stop-WithError "Не удалось узнать последнюю версию omp на GitHub: $_"
}
$ompAsset = $release.assets | Where-Object { $_.name -eq $ompAssetName } | Select-Object -First 1
if (-not $ompAsset) {
    Stop-WithError "В выпуске omp $($release.tag_name) нет файла $ompAssetName."
}
$ompSha256 = "$($ompAsset.digest)" -replace "^sha256:", ""
if ($ompSha256 -notmatch "^[0-9a-fA-F]{64}$") {
    $sums = $release.assets | Where-Object { $_.name -eq "SHA256SUMS.txt" } | Select-Object -First 1
    $sumsText = if ($sums) { Invoke-Native { & curl.exe -s -L --max-time 60 $sums.browser_download_url } } else { "" }
    # Native output arrives as an array of lines; split each one, never the joined string.
    $sumsLines = @($sumsText | ForEach-Object { "$_" -split "\r?\n" })
    $ompSha256 = ($sumsLines | Where-Object { $_ -match "^[0-9a-fA-F]{64}\s+\*?$([regex]::Escape($ompAssetName))\s*$" } | Select-Object -First 1) -replace "\s.*$", ""
}
if ($ompSha256 -notmatch "^[0-9a-fA-F]{64}$") {
    Stop-WithError "Не удалось получить контрольную сумму omp $($release.tag_name)."
}
$ompDir = Split-Path $OmpExe
New-Item -ItemType Directory -Force -Path $ompDir | Out-Null
$ompBusy = $false
if ((Test-Path -LiteralPath $OmpExe) -and (Get-FileHash -Algorithm SHA256 -LiteralPath $OmpExe).Hash -ne $ompSha256) {
    # An open assistant window (or OMP Desktop tab) keeps omp.exe locked; a
    # replace would fail half-way, so keep the working old version instead.
    try {
        [System.IO.File]::Open($OmpExe, "Open", "ReadWrite", "None").Close()
    } catch {
        $ompBusy = $true
        Write-Warn "omp сейчас запущен (открыто окно помощника) — обновление до $($release.tag_name) пропущено."
        Write-Warn "Закройте все окна помощника и запустите УСТАНОВИТЬ.cmd ещё раз, чтобы обновить."
    }
}
if (-not $ompBusy) {
    Get-VerifiedFile $ompAsset.browser_download_url $OmpExe $ompSha256 "omp $($release.tag_name) ($([math]::Round($ompAsset.size / 1MB)) МБ)"
}
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (-not (($userPath -split ";") -contains $ompDir)) {
    [Environment]::SetEnvironmentVariable("Path", (($userPath.TrimEnd(";"), $ompDir) -join ";").TrimStart(";"), "User")
}
Update-SessionPath
# Integrity is proven by the SHA-256 check; the fresh binary is not executed
# here, since "download an .exe and run it" is what behaviour-based antivirus
# (Kaspersky PDM) flags as a dropper.
Write-Ok "omp $($release.tag_name) установлен: $OmpExe"

# OMP Desktop: a windowed front end (like the Codex or Claude desktop apps)
# that runs this same omp in RPC mode, so models, keys, AGENTS.md and the
# vault guard all apply. Optional: a failure warns and setup carries on.
$DesktopExe = ""
if ($SkipDesktop) {
    Write-Warn "Окно OMP Desktop пропущено (-SkipDesktop)"
} else {
    try {
        $desktopRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/apoc/omp-desktop/releases/latest" -Headers @{ "User-Agent" = "MyLocalAI-setup" } -TimeoutSec 60
        $desktopVersion = "$($desktopRelease.tag_name)".TrimStart("v")
        $DesktopExe = Find-OmpDesktop
        $installedVersion = if ($DesktopExe) { (Get-Item -LiteralPath $DesktopExe).VersionInfo.ProductVersion } else { "" }
        if ($DesktopExe -and $installedVersion -eq $desktopVersion) {
            Write-Ok "OMP Desktop $desktopVersion уже установлен"
        } else {
            $setupAsset = $desktopRelease.assets | Where-Object { $_.name -like "*_x64-setup.exe" } | Select-Object -First 1
            $setupSha256 = "$($setupAsset.digest)" -replace "^sha256:", ""
            if (-not $setupAsset -or $setupSha256 -notmatch "^[0-9a-fA-F]{64}$") {
                throw "в выпуске $($desktopRelease.tag_name) нет установщика для Windows с контрольной суммой"
            }
            $setupPath = Join-Path $env:TEMP $setupAsset.name
            Get-VerifiedFile $setupAsset.browser_download_url $setupPath $setupSha256 "OMP Desktop $desktopVersion ($([math]::Round($setupAsset.size / 1MB)) МБ)"
            Write-Info "Устанавливаю OMP Desktop..."
            $proc = Start-Process -FilePath $setupPath -ArgumentList "/S" -Wait -PassThru
            Remove-Item -LiteralPath $setupPath -Force -ErrorAction SilentlyContinue
            $DesktopExe = Find-OmpDesktop
            if ($proc.ExitCode -ne 0 -or -not $DesktopExe) {
                throw "установщик завершился с кодом $($proc.ExitCode)"
            }
            Write-Ok "OMP Desktop $desktopVersion установлен: $DesktopExe"
        }
    } catch {
        $DesktopExe = Find-OmpDesktop
        Write-Warn "Не удалось установить OMP Desktop: $($_.Exception.Message)"
        Write-Warn "Помощник работает и без него — через окно терминала."
    }
}

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
# Named omp profiles (omp --profile, or a profile picked in OMP Desktop) use
# their own agent folder under ~/.omp/profiles, so the guard goes there too.
$vaultLiteral = ConvertTo-Json -InputObject ([string]$VaultPath) -Compress
$guard = (Get-Content -LiteralPath $GuardFile -Raw -Encoding UTF8).Replace("__VAULT__", $vaultLiteral)
$guardDirs = @($agentDir) + @(Get-ChildItem -Path (Join-Path $env:USERPROFILE ".omp\profiles\*\agent") -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
foreach ($dir in $guardDirs) {
    $hookDir = Join-Path $dir "hooks\pre"
    New-Item -ItemType Directory -Force -Path $hookDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $hookDir "vault-guard.ts"), $guard, $Utf8NoBom)
}
Write-Ok "Помощник ограничен папкой заметок: $VaultPath"
if ($guardDirs.Count -gt 1) { Write-Ok "Ограничение поставлено и в профили omp: $($guardDirs.Count - 1)" }

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
    $stopModels = @($MainModel, $FastModel, $SmartModel, $UncensoredName) | Where-Object { $_ } | Select-Object -Unique
    $comfyCommands = @($stopModels | ForEach-Object { "ollama stop $_ >nul 2>&1" }) + @(
        "cd /d $(ConvertTo-CmdArg $ComfyRoot)",
        ".\python_embeded\python.exe -s ComfyUI\main.py --windows-standalone-build",
        "pause")
    Remove-Item -LiteralPath (Join-Path $ImagesPath "start-comfyui.ps1") -Force -ErrorAction SilentlyContinue
    New-Launcher "Картинки (ComfyUI)" $comfyCommands "Генерация картинок Qwen-Image 2.1 (откроется в браузере)" ((Join-Path $ComfyRoot "python_embeded\python.exe") + ",0")

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

New-Launcher "Второй мозг (ИИ)" (Get-AssistantCommands) "Помощник с локальным ИИ для ваших заметок" "$OmpExe,0"
if ($smartReady) {
    New-Launcher "Второй мозг — умный режим (ИИ)" (Get-AssistantCommands "ollama/$SmartModel") "Помощник на большой модели ${SmartModel}: умнее, но медленнее" "$OmpExe,0"
}
if ($uncensoredReady) {
    New-Launcher "Второй мозг — без цензуры (ИИ)" (Get-AssistantCommands "ollama/$UncensoredName") "Помощник на Qwen3.8 27B без цензуры: не отказывается отвечать" "$OmpExe,0"
}
if ($DesktopExe) {
    New-Launcher "Второй мозг (окно)" @("start `"`" $(ConvertTo-CmdArg $DesktopExe) $(ConvertTo-CmdArg $VaultPath)") "Помощник в отдельном окне (OMP Desktop), открывает папку заметок" "$DesktopExe,0"
}
New-DesktopShortcut "Заметки (Obsidian)" $ObsidianExe (Split-Path $ObsidianExe) "Ваши заметки"

if (-not $SkipModels) {
    Test-ModelOnGpu $MainModel
}
if ($smartReady) {
    Test-ModelOnGpu $SmartModel
}
if ($uncensoredReady) {
    Test-ModelOnGpu $UncensoredName
}

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Green
Write-Host "   ГОТОВО!" -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Green
if ($DesktopExe) {
    Write-Host "Откройте на рабочем столе ярлык «Второй мозг (окно)» (или «Второй мозг (ИИ)» — то же в терминале) и напишите, например:"
} else {
    Write-Host "Откройте на рабочем столе ярлык «Второй мозг (ИИ)» и напишите, например:"
}
Write-Host "    Запиши: купить подарок Ане до пятницы" -ForegroundColor White
if ($smartReady) {
    Write-Host "Для сложных вопросов есть ярлык «Второй мозг — умный режим (ИИ)» — умнее, но отвечает медленнее."
}
if ($uncensoredReady) {
    Write-Host "Ярлык «Второй мозг — без цензуры (ИИ)» — модель, которая не отказывается отвечать на острые темы."
}
Write-Host "Заметки появятся в папке: $VaultPath"
if ($imagesReady) {
    Write-Host "Картинки: ярлык «Картинки (ComfyUI)» → слева «Рабочие процессы» → «Qwen-Image uncensored»."
    Write-Host "Готовые картинки сохраняются в: $(Join-Path $ComfyRoot 'ComfyUI\output')"
}
if ($OllamaModelsDir) {
    Write-Host "Модели ИИ лежат в: $OllamaModelsDir"
}
Write-Host "Файлы запуска (если ярлыков на рабочем столе нет): $LaunchersDir"
Write-Host "Журнал установки: $LogFile"

try { Stop-Transcript | Out-Null } catch { }
