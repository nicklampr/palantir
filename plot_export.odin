package palantir

// Shared "Save PNG" export for every plot widget. Each plot draws a small
// button in the top-right corner of its own rect; clicking it re-renders the
// plot offscreen into a render texture (so the whole widget is captured even
// when it is partially scrolled off-screen) and writes the result to a png in
// the working directory. Desktop only (the wasm build has no writable
// filesystem).
//
// Adapted from yggdrasil/plot_export.odin.

import "core:c"
import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

PLOT_SAVE_FEEDBACK_SECS :: 2.0

// Lowercases `title` and maps every non [a-z0-9] rune to `_`, producing a
// filesystem-safe stub, e.g. "Sine wave" -> "sine_wave".
plot_export_slug :: proc(title: string) -> string {
	buf := make([dynamic]u8, 0, len(title), context.temp_allocator)
	for i in 0 ..< len(title) {
		c := title[i]
		switch {
		case c >= 'A' && c <= 'Z':
			append(&buf, c + 32)
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9':
			append(&buf, c)
		case:
			append(&buf, '_')
		}
	}
	return string(buf[:])
}

// Unique export path for `title`: plot_<slug>_<NNN>.png, using a per-app
// counter so every save lands in its own file.
plot_export_path :: proc(app: ^App, title: string) -> string {
	path := fmt.tprintf("plot_%s_%03d.png", plot_export_slug(title), app.export_count)
	app.export_count += 1
	return path
}

// --- offscreen render helpers ------------------------------------------------

// Begins an offscreen export frame: flags `app.exporting` (so the re-rendered
// widget skips hover/input handling and the save button) and creates a render
// texture of `w` x `h`. Returns false when the size is invalid.
plot_export_begin :: proc(app: ^App, w, h: c.int) -> (rt: rl.RenderTexture2D, ok: bool) {
	if w <= 0 || h <= 0 {
		return {}, false
	}
	app.exporting = true
	return rl.LoadRenderTexture(w, h), true
}

// Ends an offscreen export frame started with `plot_export_begin`.
plot_export_finish :: proc(app: ^App, rt: rl.RenderTexture2D) {
	rl.UnloadRenderTexture(rt)
	app.exporting = false
}

// Reads an offscreen render texture, flips it (GPU textures come back
// bottom-up) and writes it to `path`.
plot_export_write :: proc(rt: rl.RenderTexture2D, path: string) -> bool {
	img := rl.LoadImageFromTexture(rt.texture)
	defer rl.UnloadImage(img)
	rl.ImageFlipVertical(&img)
	return rl.ExportImage(img, strings.clone_to_cstring(path, context.temp_allocator))
}

// Records a successful export so the widget's button shows "Saved" briefly.
plot_export_feedback :: proc(app: ^App, title: string) {
	app.save_feedback_at = rl.GetTime()
	app.save_feedback_title = title
}

// --- per-widget export procs -------------------------------------------------

plot_export_series :: proc(
	app: ^App,
	series: []PlotSeries,
	title, x_label, y_label: string,
	rect: rl.Rectangle,
	theme: Theme,
	font_size: i32,
	sc: f32,
	scatter: bool = false,
) -> bool {
	path := plot_export_path(app, title)
	rt, ok := plot_export_begin(app, c.int(rect.width), c.int(rect.height))
	if !ok {return false}
	defer plot_export_finish(app, rt)

	rl.BeginTextureMode(rt)
	plot_series(
		app,
		series,
		title,
		x_label,
		y_label,
		rl.Rectangle{0, 0, rect.width, rect.height},
		theme,
		font_size,
		sc,
		scatter,
	)
	rl.EndTextureMode()

	if plot_export_write(rt, path) {
		plot_export_feedback(app, title)
		return true
	}
	return false
}

plot_export_histogram :: proc(
	app: ^App,
	values: []f32,
	title, x_label, y_label: string,
	number_bins: int,
	rect: rl.Rectangle,
	theme: Theme,
	font_size: i32,
	sc: f32,
) -> bool {
	path := plot_export_path(app, title)
	rt, ok := plot_export_begin(app, c.int(rect.width), c.int(rect.height))
	if !ok {return false}
	defer plot_export_finish(app, rt)

	rl.BeginTextureMode(rt)
	plot_histogram(
		app,
		values,
		title,
		x_label,
		y_label,
		number_bins,
		rl.Rectangle{0, 0, rect.width, rect.height},
		theme,
		font_size,
		sc,
	)
	rl.EndTextureMode()

	if plot_export_write(rt, path) {
		plot_export_feedback(app, title)
		return true
	}
	return false
}

plot_export_histogram_2d :: proc(
	app: ^App,
	points: [][2]f64,
	title, x_label, y_label: string,
	number_bins_x, number_bins_y: int,
	rect: rl.Rectangle,
	theme: Theme,
	font_size: i32,
	sc: f32,
) -> bool {
	path := plot_export_path(app, title)
	rt, ok := plot_export_begin(app, c.int(rect.width), c.int(rect.height))
	if !ok {return false}
	defer plot_export_finish(app, rt)

	rl.BeginTextureMode(rt)
	plot_histogram_2d(
		app,
		points,
		title,
		x_label,
		y_label,
		number_bins_x,
		number_bins_y,
		rl.Rectangle{0, 0, rect.width, rect.height},
		theme,
		font_size,
		sc,
	)
	rl.EndTextureMode()

	if plot_export_write(rt, path) {
		plot_export_feedback(app, title)
		return true
	}
	return false
}

plot_export_earth_map :: proc(
	app: ^App,
	routes: []PlotRoute,
	view: ^Map_View,
	bg: ^Map_Background,
	title: string,
	rect: rl.Rectangle,
	theme: Theme,
	font_size: i32,
	sc: f32,
) -> bool {
	path := plot_export_path(app, title)
	rt, ok := plot_export_begin(app, c.int(rect.width), c.int(rect.height))
	if !ok {return false}
	defer plot_export_finish(app, rt)

	rl.BeginTextureMode(rt)
	plot_earth_map(
		app,
		routes,
		view,
		bg,
		title,
		rl.Rectangle{0, 0, rect.width, rect.height},
		theme,
		font_size,
		sc,
		false,
	)
	rl.EndTextureMode()

	if plot_export_write(rt, path) {
		plot_export_feedback(app, title)
		return true
	}
	return false
}

// --- save button -------------------------------------------------------------

// Draws a small "Save PNG" button in the top-right of `rect` and returns true
// for the frame it is clicked. The caller then re-renders itself offscreen via
// its `plot_export_*` proc. The button shows "Saved" briefly after an export.
plot_save_button :: proc(
	app: ^App,
	rect: rl.Rectangle,
	title: string,
	theme: Theme,
	sc: f32,
) -> bool {
	// Never draw the button while a plot is being rendered offscreen for export.
	if app.exporting {
		return false
	}

	label: cstring = "Save PNG"
	fs: i32 = i32(10 * sc)
	pad: f32 = 6 * sc
	tw := f32(measure_text(label, fs))
	bw := tw + pad * 2
	bh := f32(fs) + pad * 0.5
	btn := rl.Rectangle{rect.x + rect.width - bw - pad * 0.5, rect.y + pad * 0.5, bw, bh}

	mouse := rl.GetMousePosition()
	hover := rl.CheckCollisionPointRec(mouse, btn)

	// Recent export feedback, shown on the widget that produced it.
	just_saved :=
		app.save_feedback_title == title &&
		rl.GetTime() - app.save_feedback_at < PLOT_SAVE_FEEDBACK_SECS

	bg := theme.border
	if hover {
		bg = theme.axis_x
	}
	text_col := theme.text
	if just_saved {
		label = "Saved"
		text_col = theme.axis_y
	}

	rl.DrawRectangleRec(btn, bg)
	rl.DrawRectangleLinesEx(btn, 1, theme.border)
	draw_text(
		label,
		i32(btn.x + (bw - f32(measure_text(label, fs))) * 0.5),
		i32(btn.y + (bh - f32(fs)) * 0.5),
		fs,
		text_col,
	)

	return hover && rl.IsMouseButtonReleased(.LEFT) && !app.palette.open
}