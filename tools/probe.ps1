#!/usr/bin/env pwsh
# ============================================================================
# probe.ps1 — авто-телеметрия геймплея на РЕАЛЬНОМ телефоне одной командой.
#
#   pwsh tools/probe.ps1 [-Seed 7] [-DurationS 120] [-ExtraArgs "..."] [-SkipBuild] [-KeepApk]
#
# A/B рендера (B6): сравнить LOD-декор с полным PBR одной парой команд —
#   pwsh tools/probe.ps1 -ExtraArgs "--probe-s=90 --probe-seed=3000 --dormant-hi"  # бейслайн
#   pwsh tools/probe.ps1 -ExtraArgs "--probe-s=90 --probe-seed=3000"               # LOD (дефолт)
#
# Делает: собрать probe-APK (пресет Android-Probe, в нём запечён --probe-s) →
# adb install → разбудить/держать экран → запустить → стримить @TLM из logcat
# до @TLM_DONE/таймаута → выкачать авторитетный JSON через run-as (без доп.
# прав, debug-APK debuggable) → разобрать и напечатать анализ + ВЕРДИКТ.
#
# Почему пресет, а не аргументы intent: на Godot 4.4 Android `am --es/--esa
# command_line_args` НЕ доходит до OS.get_cmdline_args() (спайк S1). Запечённый
# command_line/extra_args в export_presets.cfg — доходит. Длительность правится
# там (--probe-s=N); -DurationS здесь задаёт лишь таймаут ожидания.
# ============================================================================
[CmdletBinding()]
param(
  [int]$Seed = 7,
  [int]$DurationS = 120,
  [string]$ExtraArgs = '',   # B6 A/B: переопределить baked command_line/extra_args на этот прогон (восстанавливается после)
  [switch]$SkipBuild,
  [switch]$KeepApk
)
$ErrorActionPreference = 'Stop'

$Adb   = 'C:\Android\platform-tools\adb.exe'
$Godot = 'C:\Tools\Godot-4.4.1\Godot_v4.4.1-stable_win64_console.exe'
$Pkg   = 'dev.zolotodozer.slice'
$Act   = "$Pkg/com.godot.game.GodotApp"
$Repo  = Split-Path $PSScriptRoot -Parent
$Apk   = Join-Path $Repo 'godot\build\zolotodozer-probe.apk'
$Preset = Join-Path $Repo 'godot\export_presets.cfg'
$OutDir = Join-Path $Repo 'out\telemetry'

function Info($m) { Write-Host "[probe] $m" -ForegroundColor Cyan }
function Fail($m) { Write-Host "[probe] FAIL: $m" -ForegroundColor Red; exit 1 }

# --- 0. preflight: устройство на связи? --------------------------------------
$state = (& $Adb get-state 2>&1 | Out-String).Trim()
if ($state -ne 'device') {
  & $Adb reconnect offline *> $null
  Start-Sleep 2
  $state = (& $Adb get-state 2>&1 | Out-String).Trim()
}
if ($state -ne 'device') { Fail "нет устройства (adb get-state='$state'). Подключи телефон по USB и разреши отладку." }
Info "устройство на связи"

# --- 1. сборка probe-APK ------------------------------------------------------
if (-not $SkipBuild) {
  $presetOrig = $null
  if ($ExtraArgs) {
    # A/B: запечь иные аргументы в Android-Probe на этот прогон, потом вернуть как было.
    # Меняем строку extra_args ТОЛЬКО в секции [preset.1.options] (Android-Probe),
    # чтобы не задеть пустую строку preset.0. Восстановление — в finally (даже при ошибке).
    $presetOrig = Get-Content $Preset -Raw
    $lines = $presetOrig -split "`r?`n"
    $inP1 = $false; $patched = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
      if ($lines[$i] -match '^\[preset\.1\.options\]') { $inP1 = $true; continue }
      if ($lines[$i] -match '^\[') { $inP1 = $false }
      if ($inP1 -and $lines[$i] -match '^command_line/extra_args=') {
        $lines[$i] = 'command_line/extra_args="' + $ExtraArgs + '"'; $patched = $true; break
      }
    }
    if (-not $patched) { Fail "не нашёл command_line/extra_args в [preset.1.options] для -ExtraArgs" }
    Set-Content -Path $Preset -Value ($lines -join "`n") -Encoding utf8 -NoNewline
    Info "A/B: extra_args := `"$ExtraArgs`""
  }
  Info "сборка Android-Probe APK…"
  Push-Location $Repo
  try {
    & $Godot --headless --path godot --export-debug 'Android-Probe' 'build/zolotodozer-probe.apk' 2>&1 |
      Select-String -Pattern 'error|Signed|export: end' | ForEach-Object { Write-Host "    $_" }
  } finally {
    Pop-Location
    if ($presetOrig) { Set-Content -Path $Preset -Value $presetOrig -Encoding utf8 -NoNewline; Info "preset восстановлен" }
  }
  if (-not (Test-Path $Apk)) { Fail "APK не собрался: $Apk" }
} else {
  Info "сборка пропущена (-SkipBuild)"
  if ($ExtraArgs) { Info "ВНИМАНИЕ: -ExtraArgs игнорируется при -SkipBuild (APK уже собран)" }
}
if (-not (Test-Path $Apk)) { Fail "нет APK: $Apk (убери -SkipBuild)" }

# --- 2. install ---------------------------------------------------------------
Info "установка APK…"
$inst = (& $Adb install -r $Apk 2>&1 | Out-String)
if ($inst -notmatch 'Success') { Fail "install не удался:`n$inst" }

# --- 3. экран: разбудить и держать включённым (иначе GL-цикл паузит) ----------
& $Adb shell svc power stayon usb       *> $null
& $Adb shell input keyevent KEYCODE_WAKEUP *> $null
& $Adb shell wm dismiss-keyguard        *> $null

# --- 4. инфо устройства -------------------------------------------------------
$model = (& $Adb shell getprop ro.product.model 2>&1 | Out-String).Trim()
$andr  = (& $Adb shell getprop ro.build.version.release 2>&1 | Out-String).Trim()
$size  = ((& $Adb shell wm size 2>&1 | Out-String).Trim() -replace 'Physical size:\s*','')
$gpu   = ''
try {
  $sf = (& $Adb shell dumpsys SurfaceFlinger 2>&1 | Out-String)
  $m = [regex]::Match($sf, 'GLES:\s*(.+)')
  if ($m.Success) { $gpu = $m.Groups[1].Value.Trim() }
} catch {}
$device = [ordered]@{ model = $model; android = $andr; size = $size; gpu = $gpu }
Info "device: $model (Android $andr, $size) GPU: $gpu"

# --- 5. чистый logcat + чистая папка телеметрии + запуск ----------------------
& $Adb shell am force-stop $Pkg *> $null
& $Adb shell run-as $Pkg sh -c 'rm -rf files/telemetry' *> $null  # newest = только этот прогон (игра пересоздаст каталог)
& $Adb logcat -c *> $null
Info "запуск probe (baked --probe-s, таймаут $($DurationS + 60)s)…"
& $Adb shell am start -n $Act *> $null

# --- 6. ждать @TLM_DONE (поллинг logcat -d), детект краха ----------------------
$deadline = [DateTime]::UtcNow.AddSeconds($DurationS + 60)
$done = $false; $crash = $false; $sawAny = $false; $lastTick = -1
while ([DateTime]::UtcNow -lt $deadline) {
  Start-Sleep 3
  $log = (& $Adb logcat -d 2>&1 | Out-String) -split "`n"
  $tlm = $log | Where-Object { $_ -match '@TLM' }
  if ($tlm) {
    $sawAny = $true
    # показать прогресс по последнему окну
    $lastWin = $tlm | Where-Object { $_ -match '@TLM \{' } | Select-Object -Last 1
    if ($lastWin -and $lastWin -match '"tick":(\d+)') {
      $t = [int]$Matches[1]
      if ($t -ne $lastTick) { $lastTick = $t; Write-Host "    …tick $t" -ForegroundColor DarkGray }
    }
  }
  if ($tlm | Where-Object { $_ -match '@TLM_DONE' }) { $done = $true; break }
  # Узкие сигнатуры реального краха (тег AndroidRuntime встречается в штатных логах — не ловим его).
  if ($log | Where-Object { $_ -match 'FATAL EXCEPTION|beginning of crash|SCRIPT ERROR|Parse Error' }) { $crash = $true; break }
  if (-not $sawAny) {
    $pid_ = (& $Adb shell pidof $Pkg 2>&1 | Out-String).Trim()
    if (-not $pid_) { $crash = $true; break }  # умер до первого @TLM
  }
}
if ($crash) { Info "ВНИМАНИЕ: похоже на краш/ошибку — соберу частичные данные" }
if (-not $done -and -not $crash) { Info "ВНИМАНИЕ: таймаут без @TLM_DONE — частичные данные" }

# --- 7. авторитетная выкачка JSON через run-as --------------------------------
New-Item -ItemType Directory -Force -Path $OutDir *> $null
$newest = (& $Adb exec-out run-as $Pkg sh -c 'ls -1 files/telemetry/ 2>/dev/null | tail -1' 2>&1 | Out-String).Trim()
$obj = $null; $localPath = $null
if ($newest) {
  $json = (& $Adb exec-out run-as $Pkg cat "files/telemetry/$newest" 2>&1 | Out-String)
  try { $obj = $json | ConvertFrom-Json } catch { $obj = $null }
  if ($obj) {
    $obj.device = [pscustomobject]$device   # дозаполнить инфо устройства
    $localPath = Join-Path $OutDir $newest
    ($obj | ConvertTo-Json -Depth 12) | Set-Content -Path $localPath -Encoding utf8
  }
}

# --- 8. анализ ----------------------------------------------------------------
Write-Host ""
Write-Host "================= TELEMETRY ANALYSIS =================" -ForegroundColor Yellow
if (-not $obj) {
  Write-Host "JSON не получен (newest='$newest'). Краш до дампа? Частичные @TLM в logcat."
  if ($crash) { Fail "краш на устройстве, авторитетных данных нет" }
  Fail "нет телеметрии"
}
$s = $obj.summary
"device : $($device.model)  Android $($device.android)  $($device.size)"
"gpu    : $($device.gpu)"
"run    : scenario=$($obj.scenario) seed=$($obj.seed) ticks=$($obj.ticks) dur=$($obj.duration_s)s windows=$($obj.windows.Count)"
"frame  : p50=$($s.frame_ms.p50)  p95=$($s.frame_ms.p95)  p99=$($s.frame_ms.p99)  max=$($s.frame_ms.max) ms   (бюджет 16.7)"
"physics: p50=$($s.physics_ms.p50)  p95=$($s.physics_ms.p95)  p99=$($s.physics_ms.p99)  max=$($s.physics_ms.max) ms"
"fps    : min=$($s.min_fps)   over-budget кадров: $($s.frames_over_budget_pct)%"
"render : max draw_calls=$($s.max_draw_calls)  max visible coins=$($s.max_visible_coins)  max vis_gold=$($s.max_vis_gold)"
"nodes  : start=$($s.node_count_start) end=$($s.node_count_end) leak=$($s.node_leak)"
"cap    : min=$($s.cap_min) max=$($s.cap_max)  (AIMD-бюджет; -1 = ещё не реализован, этап B2)"
Write-Host ""
if ($s.pass) {
  Write-Host "VERDICT: PASS" -ForegroundColor Green
} else {
  Write-Host "VERDICT: FAIL ($($s.fail_reasons -join '; '))" -ForegroundColor Red
}
if ($localPath) { "JSON  : $localPath" }
Write-Host "=====================================================" -ForegroundColor Yellow

if (-not $KeepApk -and -not $SkipBuild) { } # APK оставляем (быстрый -SkipBuild потом)
