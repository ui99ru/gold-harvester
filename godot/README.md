# Золотодозер — Godot 4.4.1 + Jolt

Полный порт браузерной игры (Three.js + Rapier, корень репо) — «все ценности,
от осей и камеры до вида монет и работы с воротами». Источник истины — `src/`;
палитра и свет откалиброваны по web-эталону численно (`tools/sample_patch.py`).
Петля разработки — десктоп; телефон — чекпойнты APK (CI собирает каждый пуш).

## Сцены

- `scenes/game.tscn` — **игра** (main_scene): коридор, дозер, ворота ×10/×100
  с волнами, пад НОЖ, трэш-пэд, экономика, звук, джус.
- `scenes/pusher_lab.tscn` — лоток-полигон (тест физики монет, не игра).

Сцены минимальны (корень + скрипт); вся геометрия, материалы, текстуры и UI
строятся кодом — проект живёт без редактора Godot.

## Скрипты

| Скрипт | Роль |
| --- | --- |
| `game.gd` | оркестратор: сим-шаг (порядок web simStep), ввод (драг+WASD), камера-формулы web, экономика, банк, смоук-харнесс |
| `game_config.gd` | ВСЕ константы src/config.js 1:1 (физика/камера/палитра/экономика) |
| `level_def.gd` / `entity_def.gd` | уровень = данные; `levels/level_01.tres` — web-карта |
| `dozer.gd` | ~30-деталь миниатюра + кинематика: ковш 8 коллайдеров, шасси 2 (top_level + явные позы) |
| `gates.gd` | ворота: накопление/разблок (web :439-449) и волна ×mult (web :408-438, эдж-триггер) |
| `pads.gd` / `trash_pad.gd` | пад НОЖ (апгрейд ковша) / утилизатор |
| `coin.gd` | физика 1:1 (r 0.40, friction 0.95, клэмп 12), атлас-грань со звездой, «завал плашмя» |
| `coin_pool.gd` | пул 1000: spawn/release, неактивные заморожены и без коллизий |
| `fx.gd` | 80 спрайтов (пыль/искры/всполохи) + попапы; `game_audio.gd` — движок-луп/джинглы/mute |
| `tex_gen.gd` | процедурные текстуры: грунт, монета, шеврон, небо (детерминированы) |
| `performance_hud.gd` | FPS/physics ms, прокси «≈телефон» (×8), тумблеры тюнинга |

## Запуск

```powershell
$GODOT = "C:\Tools\Godot-4.4.1\Godot_v4.4.1-stable_win64_console.exe"
& $GODOT --path godot            # игра: СТАРТ -> драг по земле / WASD, колесо = зум
```

### Смоук-тесты (headless, детерминированные, exit code)

Игра (main_scene):

```powershell
& $GODOT --headless --path godot ++ --smoke-drive     # таран столба + проезд в створ, 20 c
& $GODOT --headless --path godot ++ --smoke-push      # наезд на кучу: нет туннеля/провала, 10 c
& $GODOT --headless --path godot ++ --smoke-gatefill  # монеты в мат -> разблок ворот, 15 c
& $GODOT --headless --path godot ++ --smoke-wave      # инвариант волны: сумма worth ровно x10, 6 c
& $GODOT --headless --path godot ++ --smoke-knife     # апгрейд НОЖ: ковш шире, пад исчез, 4 c
& $GODOT --headless --path godot ++ --smoke-trash     # сжигание без банка, пул сходится, 4 c
& $GODOT --headless --path godot ++ --smoke-stress    # worst-case 1000 тел: замер физики, 10 c
```

Лоток (`$LAB = "res://scenes/pusher_lab.tscn"`): `--smoke-stack | pusher | stress | jam`.

### Скриншоты и сверка с web

```powershell
& $GODOT --path godot ++ --pose=0,14 --shot=out/x.png   # кадр в позе web-бита
npm run shoot                                            # web-эталоны (out/shot_*.png)
python tools\sample_patch.py out\shot_establish.png 520 980 680 1140   # замер патча
```

Известные грабли:

- `Engine.time_scale` растягивает шаг физики — монеты туннелируют. Смоуки в реальном времени.
- AnimatableBody3D-ребёнок движущегося узла НЕ синкается с физикой — тела
  кинематики top_level с явными позами каждый тик.
- `PHYSICS_3D_ACTIVE_OBJECTS` на Jolt всегда 0 — не верить.

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

`.github/workflows/build-android.yml`: пуш в `xp/godot` или тег `v*` →
`barichello/godot-ci:4.4.1` → debug APK в артефакте `zolotodozer-debug-apk`.
Секретов нет. Release-подпись потом: keystore base64 → Secrets.

## Замеры (прокси: десктоп-физика ×8 ≈ телефон; бюджет кадра 16.7 мс)

| Сценарий | Desktop physics | ≈Телефон | Факт телефона |
| --- | --- | --- | --- |
| Лоток 250 монет | 1.7 мс | 13.9 мс | 13.3 мс (валидация прокси) |
| Игра, worst-case 1000 бодрствующих | 16.6 мс | 132 мс | — |

Вывод: спящие кучи почти бесплатны (Jolt), бюджет ≈ **250-300 одновременно
активных** монет. При сценах масштаба 1000 активных нужен «активный пузырь»
(см. memory/BACKLOG) — следующий этап тюнинга, триггер — покраснение строки
«≈телефон» в HUD. Рендер прокси не покрывает: кандидат при дорогом рендере —
MultiMesh вместо 1000 MeshInstance3D.
