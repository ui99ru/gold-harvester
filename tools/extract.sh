#!/usr/bin/env bash
# Опора 1: корпус эталонов из demo.mp4
# Запуск из корня репо:  bash tools/extract.sh
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p refs/frames refs/keyframes

# Все кадры (720x1280). nb_frames=678 @ ~24fps, 28s.
ffmpeg -y -i demo.mp4 refs/frames/f_%04d.png

# Контактный лист: 2 кадра/сек, превью 180px, плитка 8x7 (=56 ячеек ~ 28с*2)
ffmpeg -y -i demo.mp4 -vf "fps=2,scale=180:-1,tile=8x7" refs/contact.png

# Полосы по 1 кадру/сек с таймкодом-подписью для разметки фаз
ffmpeg -y -i demo.mp4 -vf "fps=1,scale=240:-1,drawtext=text='%{pts\:hms}':x=4:y=4:fontsize=18:fontcolor=yellow:box=1:boxcolor=black@0.6,tile=7x4" refs/strip_sec.png

echo "done: $(ls refs/frames | wc -l) frames, refs/contact.png, refs/strip_sec.png"
