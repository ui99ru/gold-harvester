#!/usr/bin/env python3
"""Калибровка камеры по исчезающим точкам (VP) трёх семейств прямых.

Семейства: VERT (вертикали), LONG (вдоль коридора), LAT (поперёк).
Допущение: principal point = центр кадра. Фокус — из ортогональности VERT⊥LONG
(гарантирована геометрией мира; LAT может быть не ⊥ LONG — даёт угол ворот).

Использование:
  python tools/_calib.py selftest             # самопроверка на нашей известной камере
  python tools/_calib.py solve lines.json W H # расчёт по разметке (сегменты по семействам)

lines.json: {"VERT": [[x0,y0,x1,y1],...], "LONG": [...], "LAT": [...]}
"""
import sys, json, math
import numpy as np

try:
    sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass


# ── VP: least-squares пересечение линий ─────────────────────────────────────
def vp_from_segments(segs, W, H):
    """segs: [[x0,y0,x1,y1],...] в пикселях. Возврат VP в центрированных коордах (px)."""
    L = []
    for x0, y0, x1, y1 in segs:
        p0 = np.array([x0 - W / 2, y0 - H / 2, 1.0])
        p1 = np.array([x1 - W / 2, y1 - H / 2, 1.0])
        l = np.cross(p0, p1)
        n = math.hypot(l[0], l[1])
        if n < 1e-9:
            continue
        L.append(l / n)
    L = np.array(L)
    # VP v: L @ v = 0 → наименьший сингулярный вектор
    _, _, Vt = np.linalg.svd(L)
    v = Vt[-1]
    return v  # однородные (x,y,w), центрированные


def vp_dir(v, f):
    """Однородная VP → нормированное направление в камере (z вперёд, y вниз — экранные)."""
    if abs(v[2]) < 1e-12:
        d = np.array([v[0], v[1], 0.0])
    else:
        d = np.array([v[0] / v[2], v[1] / v[2], f])
    return d / np.linalg.norm(d)


# ── Калибровка из VERT + LONG (ортогональны всегда) ─────────────────────────
def calibrate(vps, W, H):
    """vps: {'VERT':v,'LONG':v,'LAT':v(опц)}. Возврат dict углов/фокуса."""
    vv, vl = vps['VERT'], vps['LONG']
    # к аффинным координатам (могут быть близки к бесконечности — берём через однородные):
    # f^2 = -(x1x2 + y1y2) при v=(x,y,1) обоих; обобщённо через нормированные:
    a = (vv[0] / vv[2], vv[1] / vv[2])
    b = (vl[0] / vl[2], vl[1] / vl[2])
    f2 = -(a[0] * b[0] + a[1] * b[1])
    if f2 <= 0:
        raise ValueError(f'f^2={f2:.1f} <= 0 — семейства не ортогональны или VP плохие')
    f = math.sqrt(f2)

    d_up = vp_dir(vv, f)        # направление мировой вертикали в камере (±)
    d_fwd = vp_dir(vl, f)       # направление коридора в камере (±)
    # знаки: вертикаль смотрит вверх в мире → на экране VP вертикалей обычно ниже кадра → d_y>0 — это «вниз»; берём up = -d, если d_y>0
    if d_up[1] > 0:
        d_up = -d_up
    # коридор «вперёд-вверх по экрану» → y-компонента отрицательна (экранный y вниз)
    if d_fwd[1] > 0:
        d_fwd = -d_fwd
    # ортогонализация: fwd ⊥ up
    d_fwd = d_fwd - np.dot(d_fwd, d_up) * d_up
    d_fwd /= np.linalg.norm(d_fwd)
    d_right = np.cross(d_fwd, d_up)   # правая тройка (камера: x вправо, y вниз, z вперёд)

    # Углы камеры относительно мира.
    # Мир: X=d_right_world... Проще: камера forward в мировых осях.
    # Матрица: столбцы = мировые оси в камере: [right_w, up_w, fwd_w] = [d_right, d_up, d_fwd]
    Rwc = np.column_stack([d_right, d_up, d_fwd])   # world->cam
    Rcw = Rwc.T
    # camera forward в мире = Rcw @ (0,0,1)
    fw = Rcw @ np.array([0, 0, 1.0])
    # мир: y вверх. pitch = угол вниз от горизонта; yaw = вокруг Y
    pitch = math.degrees(math.asin(-fw[1] if fw[1] < 0 else -fw[1]))   # fw[1] отрицателен (смотрим вниз)
    pitch = math.degrees(math.asin(max(-1, min(1, -fw[1]))))
    yaw = math.degrees(math.atan2(fw[0], fw[2]))
    # знак yaw неоднозначен (зеркальный базис): нормируем по экранной стороне VP коридора —
    # коридор уходит вверх-ВЛЕВО (VP x<0) → камера повернута в минус
    vl_x = vl[0] / vl[2]
    yaw = -abs(yaw) if vl_x < 0 else abs(yaw)
    # roll: куда смотрит "право" камеры в мире — компонента по вертикали
    rt = Rcw @ np.array([1, 0, 0.0])
    roll = math.degrees(math.asin(max(-1, min(1, rt[1]))))
    fovy = 2 * math.degrees(math.atan((H / 2) / f))

    out = {'f_px': f, 'fov_y': fovy, 'pitch_down': pitch, 'yaw': yaw, 'roll': roll}
    if 'LAT' in vps and vps['LAT'] is not None:
        d_lat = vp_dir(vps['LAT'], f)
        # мировое направление LAT: в мир. координатах
        lat_w = Rcw @ d_lat
        lat_w[1] = 0   # горизонтальная составляющая
        n = np.linalg.norm(lat_w)
        if n > 1e-9:
            lat_w /= n
            fwd_w = Rcw @ d_fwd
            fwd_w[1] = 0; fwd_w /= np.linalg.norm(fwd_w)
            ang = math.degrees(math.acos(max(-1, min(1, abs(np.dot(lat_w, fwd_w))))))
            out['lat_vs_long_deg'] = ang   # 90 = ворота перпендикулярны коридору
    return out


# ── Самопроверка: синтетическая разметка через нашу камеру ──────────────────
def selftest():
    W, H = 720, 1280
    # наша камера (updateCamera): dozer(0,14), camYaw .6, back 26.8, hgt 34.5, look 11, fov 47
    a, back, hgt, look = 0.6, 26.8, 34.5, 11.0
    cam = np.array([back * math.sin(a), hgt, 14 - back * math.cos(a)])
    tgt = np.array([-look * math.sin(a), 0, 14 + look * math.cos(a)])
    fv = tgt - cam; fv /= np.linalg.norm(fv)
    rv = np.cross(fv, [0, 1, 0]); rv /= np.linalg.norm(rv)
    uv = np.cross(rv, fv)
    fovy = math.radians(47); asp = W / H
    f_px_true = (H / 2) / math.tan(fovy / 2)

    def proj(p):
        p = np.array(p, float) - cam
        x, y, z = np.dot(p, rv), np.dot(p, uv), np.dot(p, fv)
        return (W / 2 + x / (z * math.tan(fovy / 2) * asp) * (W / 2), H / 2 - y / (z * math.tan(fovy / 2)) * (H / 2))

    def seg(p0, p1):
        a2, b2 = proj(p0), proj(p1)
        return [a2[0], a2[1], b2[0], b2[1]]

    lines = {
        'VERT': [seg((-4.6, 0, 20), (-4.6, 8.4, 20)), seg((4.6, 0, 20), (4.6, 8.4, 20)),
                 seg((-4.6, 0, 40), (-4.6, 8.4, 40)), seg((4.6, 0, 40), (4.6, 8.4, 40))],
        'LONG': [seg((-2.8, 0, 6), (-2.8, 0, 50)), seg((2.8, 0, 6), (2.8, 0, 50)), seg((0, 0, 6), (0, 0, 56))],
        'LAT':  [seg((-4.6, 0, 20), (4.6, 0, 20)), seg((-4.6, 8.4, 20), (4.6, 8.4, 20)), seg((-4.6, 0, 40), (4.6, 0, 40))],
    }
    vps = {k: vp_from_segments(v, W, H) for k, v in lines.items()}
    r = calibrate(vps, W, H)

    # истина
    pitch_t = math.degrees(math.asin(-fv[1]))
    yaw_t = math.degrees(math.atan2(fv[0], fv[2]))
    print('— САМОПРОВЕРКА —')
    print(f"истина:  pitch {pitch_t:.1f}°  yaw {yaw_t:.1f}°  roll 0.0°  fov_y 47.0°  f {f_px_true:.0f}px")
    print(f"восстан: pitch {r['pitch_down']:.1f}°  yaw {r['yaw']:.1f}°  roll {r['roll']:.1f}°  fov_y {r['fov_y']:.1f}°  f {r['f_px']:.0f}px")
    print(f"LAT⊥LONG (истина 90°): {r.get('lat_vs_long_deg', float('nan')):.1f}°")
    ok = (abs(r['pitch_down'] - pitch_t) < 2 and abs(r['yaw'] - yaw_t) < 2
          and abs(r['roll']) < 2 and abs(r['fov_y'] - 47) < 2 and abs(r.get('lat_vs_long_deg', 90) - 90) < 2)
    print('PASS' if ok else 'FAIL')
    return 0 if ok else 1


def solve(path, W, H):
    lines = json.load(open(path, encoding='utf-8'))
    vps = {k: vp_from_segments(v, W, H) for k, v in lines.items() if v}
    r = calibrate(vps, W, H)
    for k, v in r.items():
        print(f'{k}: {v:.2f}')


# ── Извлечение отрезков с отсевом шума ───────────────────────────────────────
UI_BOXES = [(400, 900, 720, 1040), (0, 980, 240, 1080)]   # кнопка «Пропустить», вотермарка


def extract_segs(frame_path, min_len=55):
    """Кадр → отрезки [{'seg','ang'}] ТОЛЬКО с цветовых масок структур:
    фиолетовые столбы/полосы (Hough по маске) + жёлтая кайма матов. Монеты/грунт/UI не участвуют."""
    import cv2
    from PIL import Image
    im = Image.open(frame_path).convert('RGB')
    if im.size[1] > 1080:
        im = im.crop((0, 0, 720, 1080))
    hsv = np.asarray(im.convert('HSV'), float)
    Hh, S, V = hsv[..., 0], hsv[..., 1], hsv[..., 2]
    purple = ((Hh > 140) & (Hh < 205) & (S > 70) & (V > 40) & (V < 170)).astype(np.uint8) * 255
    yellow = ((Hh > 25) & (Hh < 48) & (S > 120) & (V > 150)).astype(np.uint8) * 255
    for x0, y0, x1, y1 in UI_BOXES:
        purple[y0:y1, x0:x1] = 0; yellow[y0:y1, x0:x1] = 0
    purple[:40, :] = 0; yellow[:40, :] = 0
    g = cv2.cvtColor(np.asarray(im), cv2.COLOR_RGB2GRAY)
    g = cv2.bilateralFilter(g, 7, 50, 50)
    out = []

    def hough(edge_img, mlen, ox=0, oy=0):
        ls = cv2.HoughLinesP(edge_img, 1, np.pi / 360, threshold=26, minLineLength=mlen, maxLineGap=7)
        if ls is None:
            return
        for l in ls:
            a, b, c2, d2 = map(int, l[0])
            ang = math.degrees(math.atan2(d2 - b, c2 - a)) % 180
            out.append({'seg': [a + ox, b + oy, c2 + ox, d2 + oy], 'ang': round(ang, 1)})

    # LONG/LAT: рёбра цветовых масок (длинные кромки полос/матов)
    for mask in (purple, yellow):
        m = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
        hough(cv2.Canny(m, 50, 150), min_len)
    # VERT: вытянутые фиолетовые компоненты (столбы) → границы маски по строкам → фит двух рёбер.
    # Детерминированно и чисто: монеты в маску не входят, Hough не нужен.
    nlab, lab, stats, _ = cv2.connectedComponentsWithStats(purple, 8)
    for i in range(1, nlab):
        x, y, w, h, area = stats[i]
        if h < 100 or h / max(w, 1) < 1.5 or area < 400:
            continue
        comp = (lab[y:y + h, x:x + w] == i)
        rows, lefts, rights, widths = [], [], [], []
        for ry in range(h):
            xs = np.where(comp[ry])[0]
            if len(xs) < 3:
                continue
            rows.append(ry); lefts.append(xs[0]); rights.append(xs[-1]); widths.append(xs[-1] - xs[0])
        if len(rows) < 40:
            continue
        widths = np.array(widths, float); rows = np.array(rows); lefts = np.array(lefts, float); rights = np.array(rights, float)
        medw = np.median(widths)
        ok = np.abs(widths - medw) < max(4, 0.25 * medw)   # строки «чистого ствола» (шеврон/основание шире — отпадут)
        if ok.sum() < 40:
            continue
        for side in (lefts, rights):
            yy = rows[ok].astype(float); xx = side[ok]
            a, b = np.polyfit(yy, xx, 1)                    # x = a*y + b
            y0f, y1f = yy.min(), yy.max()
            out.append({'seg': [int(a * y0f + b + x), int(y0f + y), int(a * y1f + b + x), int(y1f + y)],
                        'ang': round(math.degrees(math.atan2(y1f - y0f, a * (y1f - y0f))) % 180, 1)})
    return im, out


# ── RANSAC VP: выбросы не голосуют ───────────────────────────────────────────
def ransac_vp(segs, W, H, tol_deg=1.5, iters=400, seed=7, domain=None):
    """segs: [[x0,y0,x1,y1],...]. VP по консенсусу: инлайер = отрезок, чьё направление
    смотрит на VP с точностью tol_deg. domain(x_px,y_px)->bool — физическое ограничение зоны VP.
    Возврат (vp, инлайеры)."""
    rng = np.random.default_rng(seed)
    def to_line(s):
        p0 = np.array([s[0] - W / 2, s[1] - H / 2, 1.0]); p1 = np.array([s[2] - W / 2, s[3] - H / 2, 1.0])
        l = np.cross(p0, p1); return l / math.hypot(l[0], l[1])
    def ang_resid(s, v):
        mx, my = (s[0] + s[2]) / 2 - W / 2, (s[1] + s[3]) / 2 - H / 2
        if abs(v[2]) > 1e-9:
            dvx, dvy = v[0] / v[2] - mx, v[1] / v[2] - my
        else:
            dvx, dvy = v[0], v[1]
        d = math.degrees(abs(math.atan2(s[3] - s[1], s[2] - s[0]) - math.atan2(dvy, dvx)))
        d %= 180
        return min(d, 180 - d)
    n = len(segs)
    if n < 2:
        return None, []
    best_inl = []
    for _ in range(iters):
        i, j = rng.choice(n, 2, replace=False)
        v = np.cross(to_line(segs[i]), to_line(segs[j]))
        if np.linalg.norm(v) < 1e-12:
            continue
        if domain is not None:
            if abs(v[2]) > 1e-9:
                vx, vy = v[0] / v[2] + W / 2, v[1] / v[2] + H / 2
            else:
                vx, vy = v[0] * 1e9, v[1] * 1e9
            if not domain(vx, vy):
                continue
        inl = [k for k in range(n) if ang_resid(segs[k], v) < tol_deg]
        if len(inl) > len(best_inl):
            best_inl = inl
    if len(best_inl) < 2:
        return None, []
    L = np.array([to_line(segs[k]) for k in best_inl])
    _, _, Vt = np.linalg.svd(L)
    return Vt[-1], best_inl


# ── Батч: много кадров → статистика доминирующей камеры ─────────────────────
FAM_WIN = {'VERT': (65, 115), 'LONG': (120, 160), 'LAT': (12, 48)}
FAM_MIN = {'VERT': 5, 'LONG': 4, 'LAT': 3}


def curate(segs):
    fam = {k: [] for k in FAM_WIN}
    for o in segs:
        a = o['ang']
        for k, (lo, hi) in FAM_WIN.items():
            if lo <= a <= hi:
                fam[k].append(o['seg'])
    return fam


DOMAINS = {
    # VP вертикалей: ниже кадра, конечная; pitch 30..75° при f~1400px → y ≈ 950..3200
    'VERT': lambda x, y: 950 < y < 3200 and -700 < x < 1400,
    'LONG': lambda x, y: -9000 < y < 300,                       # VP коридора — выше кадра, конечная
    'LAT':  lambda x, y: x < -500 or x > 1200,                  # VP поперечной — далеко сбоку
}


def solve_frame(frame_path, W=720, H=1080):
    im, segs = extract_segs(frame_path)
    fam = curate(segs)
    vps, inls = {}, {}
    for k, ss in fam.items():
        if k == 'VERT':
            # рёбра столбов (фит границ маски): группируем в столбы по x, VP по паре рёбер каждого столба,
            # нефизичные столбы (загрязнённая граница → VP вне домена) отбрасываем, итог — LSQ по прошедшим.
            ss = [s for s in ss if math.hypot(s[2] - s[0], s[3] - s[1]) >= 100]
            ss = [s for s in ss if 80 <= (math.degrees(math.atan2(s[3] - s[1], s[2] - s[0])) % 180) <= 100]
            ss.sort(key=lambda s: (s[0] + s[2]) / 2)
            posts, cur = [], []
            for s in ss:
                if cur and (s[0] + s[2]) / 2 - (cur[-1][0] + cur[-1][2]) / 2 > 90:
                    posts.append(cur); cur = []
                cur.append(s)
            if cur:
                posts.append(cur)
            good = []
            for p in posts:
                if len(p) < 2:
                    continue
                v = vp_from_segments(p, W, H)
                if abs(v[2]) > 1e-9 and DOMAINS['VERT'](v[0] / v[2] + W / 2, v[1] / v[2] + H / 2):
                    good.extend(p)
            if len(good) >= 2:
                v = vp_from_segments(good, W, H)
                if abs(v[2]) > 1e-9 and DOMAINS['VERT'](v[0] / v[2] + W / 2, v[1] / v[2] + H / 2):
                    vps[k] = v; inls[k] = good
            continue
        v, inl = ransac_vp(ss, W, H, domain=DOMAINS.get(k))
        if v is not None and len(inl) >= FAM_MIN[k]:
            vps[k] = v; inls[k] = [ss[i] for i in inl]
    if 'VERT' not in vps or 'LONG' not in vps:
        return None, im, inls
    r = calibrate(vps, W, H)
    r['fov_y'] = 2 * math.degrees(math.atan(540 / r['f_px']))
    r['n'] = {k: len(v) for k, v in inls.items()}
    # санити-гейты: игровая камера сверху-вниз, без сильного крена, разумный fov
    if not (25 < r['fov_y'] < 75 and 30 < r['pitch_down'] < 75 and abs(r['roll']) < 10):
        return None, im, inls
    return r, im, inls


def batch(frames_glob, step=5, report='out/calib_report.md'):
    import glob
    rows = []
    files = sorted(glob.glob(frames_glob))[::step]
    for p in files:
        try:
            r, _, _ = solve_frame(p)
        except Exception:
            r = None
        if r is None:
            continue
        name = p.replace('\\', '/').split('/')[-1]
        rows.append((name, r))
        print(f"{name}: pitch {r['pitch_down']:.1f} yaw {r['yaw']:.1f} roll {r['roll']:.1f} fov {r['fov_y']:.1f} ortho {r.get('lat_vs_long_deg', float('nan')):.1f} n={r['n']}")
    if not rows:
        print('нет валидных кадров'); return
    arr = {k: np.array([r[k] for _, r in rows]) for k in ['pitch_down', 'yaw', 'roll', 'fov_y']}
    lines = ['# Калибровка камеры рефа — батч', '', f'кадров с решением: {len(rows)}', '',
             '| метрика | медиана | p25 | p75 |', '|---|---|---|---|']
    for k, a in arr.items():
        lines.append(f'| {k} | {np.median(a):.1f} | {np.percentile(a, 25):.1f} | {np.percentile(a, 75):.1f} |')
    ortho = np.array([r.get('lat_vs_long_deg') for _, r in rows if 'lat_vs_long_deg' in r])
    if len(ortho):
        lines.append(f'| ворота-vs-коридор | {np.median(ortho):.1f} | {np.percentile(ortho, 25):.1f} | {np.percentile(ortho, 75):.1f} |')
    rep = '\n'.join(lines)
    open(report, 'w', encoding='utf-8').write(rep + '\n')
    print(); print(rep)


def annotate_inliers(frame_path, out_png):
    """Оверлей только инлайеров RANSAC (чистая разметка для ревью)."""
    from PIL import ImageDraw
    r, im, inls = solve_frame(frame_path)
    d = ImageDraw.Draw(im)
    col = {'VERT': (255, 70, 70), 'LONG': (60, 255, 60), 'LAT': (60, 140, 255)}
    for k, ss in inls.items():
        for s in ss:
            d.line([(s[0], s[1]), (s[2], s[3])], fill=col[k], width=3)
    im.save(out_png)
    print('->', out_png, ' result:', {kk: round(vv, 1) for kk, vv in r.items() if isinstance(vv, float)} if r else None)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'selftest':
        sys.exit(selftest())
    elif len(sys.argv) > 3 and sys.argv[1] == 'solve':
        solve(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
    elif len(sys.argv) > 2 and sys.argv[1] == 'frame':
        annotate_inliers(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else 'out/calib_frame.png')
    elif len(sys.argv) > 2 and sys.argv[1] == 'batch':
        batch(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 5)
    else:
        print(__doc__)
