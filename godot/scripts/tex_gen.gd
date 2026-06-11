class_name TexGen
## Процедурные текстуры — порт canvas-генераторов web-версии (src/main.js).
## Все детерминированы (trig+hash, без RNG) — скриншоты воспроизводимы.


## Грунт: лавандовая база + бесшовный value-noise (пятна) + зерно (main.js:27-40).
static func ground_albedo() -> ImageTexture:
	return ImageTexture.create_from_image(_ground_image(false))


## Та же карта как высоты -> normal map (web: bumpMap, bumpScale 0.6).
static func ground_normal() -> ImageTexture:
	var img := _ground_image(true)
	img.bump_map_to_normal_map(0.6)
	return ImageTexture.create_from_image(img)


static func _ground_image(as_height: bool) -> Image:
	var s := 256
	var img := Image.create(s, s, false, Image.FORMAT_RGB8)
	var bc := CFG.GROUND_COLOR
	for j in s:
		for i in s:
			var u := float(i) / s
			var v := float(j) / s
			var n := sin(u * TAU * 3) * cos(v * TAU * 3) * 0.5 \
				+ sin(u * TAU * 7 + 1.3) * cos(v * TAU * 5 + 2.1) * 0.25 \
				+ sin(u * TAU * 13 + 0.7) * cos(v * TAU * 11 + 4.2) * 0.13
			var hh := sin(i * 12.9898 + j * 78.233) * 43758.5453
			var g := (hh - floorf(hh)) - 0.5
			var k := 1.0 + n * 0.12 + g * 0.07
			if as_height:
				var h := clampf(k - 0.81, 0.0, 1.0)  # центрировать ~0.19..0.38
				img.set_pixel(i, j, Color(h, h, h))
			else:
				img.set_pixel(i, j, Color(
					minf(1.0, bc.r * k), minf(1.0, bc.g * k), minf(1.0, bc.b * k)))
	return img


## Атлас монеты под UV CylinderMesh (бок — верхняя половина, крышки — два круга
## снизу): грань web coinFaceTex (main.js:115-127) = кольцевое углубление +
## звезда-гравировка, затонированная золотом; бок — золото темнее (#e0a52e).
static func coin_atlas() -> ImageTexture:
	return ImageTexture.create_from_image(_coin_image(false))


static func coin_normal() -> ImageTexture:
	var img := _coin_image(true)
	img.bump_map_to_normal_map(1.4)
	return ImageTexture.create_from_image(img)


static func _coin_image(as_height: bool) -> Image:
	var s := 256
	var img := Image.create(s, s, false, Image.FORMAT_RGB8)
	var gold := CFG.COIN_COLOR
	var side := Color("e0a52e")
	var dark := Color("3a2406")
	img.fill(Color(0.6, 0.6, 0.6) if as_height else side)
	for cap_cx: int in [64, 192]:  # два круга-крышки в нижней половине
		for j in range(128, 256):
			for i in range(cap_cx - 64, cap_cx + 64):
				var dx := (i - cap_cx) / 64.0
				var dy := (j - 192) / 64.0
				var r := Vector2(dx, dy).length()
				if r > 1.0:
					continue
				if as_height:
					var h := 0.6
					if absf(r - 0.86) < 0.06:
						h = 1.0                      # приподнятый ободок
					elif absf(r - 0.72) < 0.05:
						h = 0.16                     # кольцевое углубление
					elif _in_star(dx, dy):
						h = 0.15                     # звезда — углубление
					img.set_pixel(i, j, Color(h, h, h))
				else:
					var c := gold
					c = c.lerp(dark, 0.32 * clampf((r - 0.34) / 0.66, 0.0, 1.0))  # округлость
					if absf(r - 0.78) < 0.04:
						c = c.lerp(dark, 0.5)        # кольцевое углубление
					elif absf(r - 0.72) < 0.015:
						c = c.lerp(Color.WHITE, 0.45)  # блик-ободок
					if _in_star(dx, dy):
						c = c.lerp(dark, 0.42)       # знак-звезда
					img.set_pixel(i, j, c)
	return img


## Точка внутри 5-конечной звезды (web: 10 вершин, r 19/8 от 64 -> 0.30/0.125)
static func _in_star(dx: float, dy: float) -> bool:
	var a := atan2(dy, dx) + PI / 2.0
	var seg := fposmod(a, PI / 2.5) / (PI / 2.5)   # сектор между лучами
	var k := minf(seg, 1.0 - seg) * 2.0            # 0 у луча, 1 между
	var rr := lerpf(0.30, 0.125, k)
	return Vector2(dx, dy).length() < rr


## Красно-белый полосатый шеврон запертых ворот (web gateTex 'red', main.js:158-161).
## Текст xN — отдельным Label3D поверх.
static func gate_chevron() -> ImageTexture:
	var img := Image.create(256, 256, false, Image.FORMAT_RGB8)
	var red := Color("e8392f")
	var ca := cos(0.5)
	var sa := sin(0.5)
	for j in 256:
		for i in 256:
			# инверсия web-поворота на -0.5: поворачиваем координату на +0.5
			var x := float(i - 128)
			var y := float(j - 128)
			var rx := x * ca - y * sa
			var stripe := fposmod(rx + 320.0, 56.0) < 28.0
			img.set_pixel(i, j, red if stripe else Color.WHITE)
	return ImageTexture.create_from_image(img)


## Небо-градиент для рефлексов золота (main.js:18-20): вертикальный, 16x64.
## Web: t=0 низ (сине-фиолетовый), t=1 верх (тёплый). В Godot строка 0 = зенит.
static func sky_panorama() -> ImageTexture:
	var img := Image.create(16, 64, false, Image.FORMAT_RGB8)
	for y in 64:
		var t := 1.0 - float(y) / 63.0  # строка 0 = верх = t=1
		var r := (110.0 + t * 120.0) * 0.45 / 255.0
		var g := (140.0 + t * 90.0) * 0.45 / 255.0
		var b := (196.0 - t * 120.0) * 0.5 / 255.0
		for x in 16:
			img.set_pixel(x, y, Color(r, g, b))
	return ImageTexture.create_from_image(img)
