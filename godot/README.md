# Золотодозер — нативный прототип (Godot 4.4.1 + Jolt)

Вертикальный срез по [docs/brief-zolotodozer-godot.md](../docs/brief-zolotodozer-godot.md):
coin pusher с физикой монет, перенесённой из Three.js-версии (корень репо).
Цель — замерить отзывчивость и производительность нативного стека на Android
против браузерной версии.

## Архитектура

Сцены (`scenes/*.tscn`) — один корневой узел + скрипт; вся геометрия, материалы
и UI строятся кодом в `scripts/*.gd`. Это позволяет работать с проектом без
редактора Godot.

| Скрипт | Роль |
|---|---|
| `main.gd` | сцена, лоток, пул 250 монет, тап-спавн, зона сбора, смоук-тесты |
| `coin.gd` | RigidBody3D: r=0.40, h=0.085, friction 0.95, damp 0.8/0.9, клэмп 12 м/с |
| `pusher.gd` | AnimatableBody3D, синусоида (период 2.5 с, амплитуда 1.8) |
| `performance_hud.gd` | FPS, frame/physics ms, активные тела, пул, кнопка «+50» |

Физика: Jolt, gravity 30 (3×), 60 тиков/с, velocity_steps 8.
Над толкателем — статический «капот»-скребок: монеты с его крыши ссыпаются на
дно при отходе (без него куча не двигалась — монеты катались на толкателе).

## Запуск на десктопе

```powershell
$GODOT = "C:\Tools\Godot-4.4.1\Godot_v4.4.1-stable_win64_console.exe"
& $GODOT --path godot
```

Мышь эмулирует тап (`emulate_touch_from_mouse`). Тап — монета над точкой.

### Смоук-тесты (headless, детерминированные, exit code)

```powershell
& $GODOT --headless --path godot ++ --smoke-stack    # стэкинг 50 монет, 6 c
& $GODOT --headless --path godot ++ --smoke-pusher   # толкатель довозит до сбора, 30 c
& $GODOT --headless --path godot ++ --smoke-stress   # весь пул 250, замер физики, 10 c
```

### Скриншоты

```powershell
& $GODOT --path godot ++ --shot=out/shot.png              # пустая сцена
& $GODOT --path godot ++ --drop-demo --shot=out/demo.png  # 50 монет + кадр
```

Известная грабля: `Engine.time_scale` растягивает эффективный шаг физики —
монеты туннелируют сквозь дно. Смоуки идут в реальном времени.

## Локальная сборка APK

Один раз:
1. Godot 4.4.1 + export templates (распаковать .tpz в
   `%APPDATA%\Godot\export_templates\4.4.1.stable\`).
2. JDK 17 (Temurin), Android SDK: `sdkmanager "platform-tools"
   "build-tools;34.0.0" "platforms;android-34"` (SDK root `C:\Android`).
3. Debug keystore: `keytool -genkeypair -keyalg RSA -alias androiddebugkey
   -keypass android -storepass android -keystore C:\Android\debug.keystore
   -dname "CN=Android Debug,O=Android,C=US" -validity 9999`.
4. В `%APPDATA%\Godot\editor_settings-4.4.tres` (`[resource]`):
   `export/android/java_sdk_path`, `android_sdk_path`, `debug_keystore`,
   `debug_keystore_user`, `debug_keystore_pass`.

Сборка:

```powershell
& $GODOT --headless --path godot --export-debug "Android" build/zolotodozer-debug.apk
adb install -r godot\build\zolotodozer-debug.apk
```

Грабля: в `project.godot` обязателен
`rendering/textures/vram_compression/import_etc2_astc=true` — без него
Android-экспорт падает с **пустым** списком configuration errors.

## CI

`.github/workflows/build-android.yml`: пуш тега `v*` (или workflow_dispatch из
default-ветки) → образ `barichello/godot-ci:4.4.1` → debug APK в артефакте
`zolotodozer-debug-apk`. Секретов нет — debug keystore из образа/keytool.
Release-подпись (база на будущее): keystore в base64 → Secrets
(`ANDROID_KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`), декодировать в шаге,
путь через `GODOT_ANDROID_KEYSTORE_RELEASE_PATH` и т.п.

## Замеры

| Сценарий | Платформа | Результат |
|---|---|---|
| smoke-stress: 250 монет, 10 с | Desktop (Ryzen/RTX 3060) | avg physics **1.75 мс** |
| 250 монет на устройстве | Snapdragon 7-й серии | TODO: HUD на телефоне |

Тюнинг по результатам (бриф §7, по одному изменению): тени off → MSAA off →
тики 60→50 → sleep-пороги Jolt → CCD точечно при туннелировании.
