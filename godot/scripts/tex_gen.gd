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
