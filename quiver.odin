package palantir

// 2D quiver (vector field) plot widget, matplotlib-style.
//
// Position/component arrays may be given in either of two forms, detected
// automatically:
//   - scattered: arrow k sits at (X[k], Y[k]) with components (U[k], V[k]);
//     arrays are independent, may differ in length, and are paired by index
//     (effective count = the min across them).
//   - regular grid: X and Y are the compact coordinate axes (each length nx/ny)
//     and U/V are their flattened product (len = nx*ny). The grid is expanded
//     in x-slowest order, so each arrow's position is (X[ix], Y[iy]).
//
// Rendering mirrors the other plot widgets: padded data bounds, grid + ticks,
// axis labels, per-magnitude coloring (seaborn style), a hover tooltip, a
// "Save PNG" button, and a `− N× +` arrow-size multiplier. Arrows auto-scale
// so the longest one maps to a readable fraction of the plot area
// (matplotlib's default behavior), then the user multiplier is applied.

import "core:fmt"
import "core:math"
import "core:strings"
import rl "vendor:raylib"

Quiver2D :: struct {
	x, y: f64, // tail position
	u, v: f64, // vector components
}

// Length of the clean (no NaN holes) non-NaN prefix of `a`. The app's JSON
// loader NaN-pads shorter columns to the dataset row count, so a compact
// coordinate axis surfaces as a valid prefix followed by NaNs.
valid_prefix_len :: proc(a: []f64) -> int {
	last := -1
	for v, i in a {
		if !math.is_nan(v) {
			last = i
		}
	}
	if last < 0 {
		return 0
	}
	// Any NaN before the last valid value means the data is not a padded
	// prefix; treat the whole array as scattered instead.
	for i in 0 ..= last {
		if math.is_nan(a[i]) {
			return 0
		}
	}
	return last + 1
}

// Turns the four arrays into arrows. When U/V are the flattened product of the
// compact X/Y axes (len(U) == len(V) == nx*ny) the grid is expanded; otherwise
// the arrays are index-paired and the result is as long as the shortest input.
quiver2d_from_arrays :: proc(X, Y, U, V: []f64) -> []Quiver2D {
	nx := valid_prefix_len(X)
	ny := valid_prefix_len(Y)
	if nx >= 1 && ny >= 1 && len(U) == nx * ny && len(V) == nx * ny {
		out := make([]Quiver2D, nx * ny, context.temp_allocator)
		k := 0
		for ix in 0 ..< nx {
			for iy in 0 ..< ny {
				out[k] = Quiver2D{x = X[ix], y = Y[iy], u = U[k], v = V[k]}
				k += 1
			}
		}
		return out
	}
	n := min(len(X), len(Y), len(U), len(V))
	out := make([]Quiver2D, n, context.temp_allocator)
	for i in 0 ..< n {
		out[i] = Quiver2D{x = X[i], y = Y[i], u = U[i], v = V[i]}
	}
	return out
}

// Min/max of each vector magnitude (NaN entries ignored). A degenerate domain
// is expanded by 1 so the colormap never divides by zero.
quiver2d_magnitude_range :: proc(arrows: []Quiver2D) -> (lo, hi: f64, ok: bool) {
	lo = math.inf_f64(1)
	hi = math.inf_f64(-1)
	for a in arrows {
		if math.is_nan(a.u) || math.is_nan(a.v) {
			continue
		}
		m := math.sqrt(a.u * a.u + a.v * a.v)
		lo = min(lo, m)
		hi = max(hi, m)
		ok = true
	}
	if !ok {
		return 0, 1, false
	}
	if lo == hi {
		hi = lo + 1
	}
	return
}

// Data bounds covering both tails and heads, NaN-safe. `ok` is false when no
// arrow has finite values.
quiver2d_bounds :: proc(arrows: []Quiver2D) -> (minp, maxp: [2]f64, ok: bool) {
	minp = {math.inf_f64(1), math.inf_f64(1)}
	maxp = {math.inf_f64(-1), math.inf_f64(-1)}
	for a in arrows {
		if math.is_nan(a.x) || math.is_nan(a.y) || math.is_nan(a.u) || math.is_nan(a.v) {
			continue
		}
		minp[0] = min(minp[0], a.x, a.x + a.u)
		maxp[0] = max(maxp[0], a.x, a.x + a.u)
		minp[1] = min(minp[1], a.y, a.y + a.v)
		maxp[1] = max(maxp[1], a.y, a.y + a.v)
		ok = true
	}
	return
}

// Uniform arrow scale factor so the longest arrow maps to ~`target_px` screen
// pixels (matplotlib-style auto-scaling). `lengths_px` holds the natural
// on-screen length of every arrow; the factor scales small fields up and large
// fields down so the field always reads. Returns 1 for empty/degenerate input.
quiver2d_autoscale :: proc(lengths_px: []f64, target_px: f64) -> f64 {
	max_len := f64(0)
	for l in lengths_px {
		if math.is_nan(l) {
			continue
		}
		max_len = max(max_len, l)
	}
	if max_len <= 0 {
		return 1
	}
	return clamp(target_px / max_len, 0.02, 10)
}

// Two barb end points for an arrowhead. `head` is the arrow tip and `dir` the
// unit shaft direction (tail -> head), both in screen pixels. Each barb is
// `head_px` long and spread `angle` (radians) from the reverse shaft direction.
quiver2d_head_barbs :: proc(
	head, dir: [2]f64,
	head_px, angle: f64,
) -> (b1, b2: [2]f64) {
	// Barbs point back toward the tail, rotated ±angle around the shaft.
	bx, by := -dir.x, -dir.y
	ca, sa := math.cos(angle), math.sin(angle)
	b1 = [2]f64{head.x + head_px * (bx * ca - by * sa), head.y + head_px * (bx * sa + by * ca)}
	b2 = [2]f64{head.x + head_px * (bx * ca + by * sa), head.y + head_px * (-bx * sa + by * ca)}
	return
}

QUIVER_HEAD_ANGLE :: 25.0 * math.PI / 180.0

// Draws the 2D quiver plot inside `rect`. X/Y are the arrow tails and U/V the
// vector components (see quiver2d_from_arrays for the grid/scattered forms).
// `scale` is a user arrow-size multiplier applied on top of the auto-scaling;
// when `scale_edit` is non-nil a `− N× +` stepper is drawn (and hidden during
// PNG export, like the histogram bin stepper).
plot_quiver :: proc(
	app: ^App,
	X, Y, U, V: []f64,
	title, x_label, y_label: string,
	rect: rl.Rectangle,
	theme: Theme,
	font_size: i32,
	ui_scale: f32 = 1,
	scale: f32 = 1,
	scale_edit: ^f32 = nil,
) {
	sc := ui_scale
	draw_fill_rounded(rect, theme.window_bg, UI_RADIUS_SM * sc)

	title_cstr := strings.clone_to_cstring(title, context.temp_allocator)
	draw_text(title_cstr, i32(rect.x + 8 * sc), i32(rect.y + 4 * sc), i32(11 * sc), theme.muted)

	plot_area := plot_area_of(rect, lineplot_margins, sc)

	arrows := quiver2d_from_arrays(X, Y, U, V)
	minp, maxp, ok := quiver2d_bounds(arrows)
	if !ok {
		draw_text("No data", i32(plot_area.x), i32(plot_area.y), i32(10 * sc), theme.text)
		return
	}

	x_pad := (maxp[0] - minp[0]) * 0.05
	y_pad := (maxp[1] - minp[1]) * 0.1
	x_min := minp[0] - x_pad
	x_max := maxp[0] + x_pad
	y_min := minp[1] - y_pad
	y_max := maxp[1] + y_pad
	if same_value(x_min, x_max) {x_max = x_min + 1}
	if same_value(y_min, y_max) {y_max = y_min + 1}
	x_range := x_max - x_min
	y_range := y_max - y_min

	// Grid + tick labels.
	for i := 0; i <= 4; i += 1 {
		t := f64(i) / 4.0
		gx := x_min + t * x_range
		gy := y_min + t * y_range
		sx := plot_area.x + f32((gx - x_min) / x_range) * plot_area.width
		sy := plot_area.y + plot_area.height - f32((gy - y_min) / y_range) * plot_area.height

		rl.DrawLine(
			i32(plot_area.x),
			i32(sy),
			i32(plot_area.x + plot_area.width),
			i32(sy),
			theme.grid,
		)
		rl.DrawLine(
			i32(sx),
			i32(plot_area.y),
			i32(sx),
			i32(plot_area.y + plot_area.height),
			theme.grid,
		)

		x_lbl := strings.clone_to_cstring(fmt.tprintf("%.2f", gx), context.temp_allocator)
		y_lbl := strings.clone_to_cstring(fmt.tprintf("%.2f", gy), context.temp_allocator)
		draw_text(
			x_lbl,
			i32(sx - 20 * sc),
			i32(plot_area.y + plot_area.height + 2 * sc),
			font_size - 2,
			theme.text,
		)
		draw_text(y_lbl, i32(plot_area.x - 60 * sc), i32(sy - 8 * sc), font_size - 2, theme.text)
	}

	draw_plot_axis_labels(rect, plot_area, x_label, y_label, theme, font_size, sc)

	mag_lo, mag_hi, mag_ok := quiver2d_magnitude_range(arrows)

	// Natural on-screen length per arrow, in the data transform's pixel space.
	screen_len := make([]f64, len(arrows), context.temp_allocator)
	for a, i in arrows {
		if math.is_nan(a.x) || math.is_nan(a.y) || math.is_nan(a.u) || math.is_nan(a.v) {
			screen_len[i] = 0
			continue
		}
		dx := (a.u / x_range) * f64(plot_area.width)
		dy := (a.v / y_range) * f64(plot_area.height)
		screen_len[i] = math.sqrt(dx * dx + dy * dy)
	}
	// Longest arrow maps to ~30% of the plot's smaller side, so dense fields
	// read without the arrows piling on top of each other.
	target_px := f64(max(0.3 * min(plot_area.width, plot_area.height), 24.0))
	factor := quiver2d_autoscale(screen_len, target_px) * f64(scale)

	line_w := max(1.0, 1.25 * sc)

	to_screen :: proc(plot_area: rl.Rectangle, x_min, y_min, x_range, y_range: f64, x, y: f64) -> rl.Vector2 {
		return rl.Vector2 {
			plot_area.x + f32((x - x_min) / x_range) * plot_area.width,
			plot_area.y + plot_area.height - f32((y - y_min) / y_range) * plot_area.height,
		}
	}

	// Arrows.
	for a, i in arrows {
		if math.is_nan(a.x) || math.is_nan(a.y) || math.is_nan(a.u) || math.is_nan(a.v) {
			continue
		}
		tail := to_screen(plot_area, x_min, y_min, x_range, y_range, a.x, a.y)
		head := to_screen(plot_area, x_min, y_min, x_range, y_range, a.x + a.u, a.y + a.v)

		dx := f64(head.x - tail.x)
		dy := f64(head.y - tail.y)
		len_px := screen_len[i] * factor
		if len_px < 1 {
			continue
		}
		ux, uy := dx / math.sqrt(dx * dx + dy * dy), dy / math.sqrt(dx * dx + dy * dy)
		// Scale the natural direction so the arrow is `len_px` long on screen.
		head = rl.Vector2{tail.x + f32(ux * len_px), tail.y + f32(uy * len_px)}

		col := theme.axis_x
		if mag_ok {
			m := math.sqrt(a.u * a.u + a.v * a.v)
			if !math.is_nan(m) {
				col = hue_lookup(mag_lo, mag_hi, m, theme.axis_x, theme.axis_z)
			}
		}

		rl.DrawLineEx(tail, head, line_w, col)

		head_px := f64(min(0.30 * len_px, 14.0 * f64(sc)))
		if head_px < 4 {
			head_px = 4
		}
		b1, b2 := quiver2d_head_barbs({f64(head.x), f64(head.y)}, {ux, uy}, head_px, QUIVER_HEAD_ANGLE)
		rl.DrawLineEx(head, rl.Vector2{f32(b1.x), f32(b1.y)}, line_w, col)
		rl.DrawLineEx(head, rl.Vector2{f32(b2.x), f32(b2.y)}, line_w, col)
	}

	// Hover tooltip: nearest arrow tail within a screen threshold.
	mouse := rl.GetMousePosition()
	if mouse.x >= plot_area.x &&
	   mouse.x <= plot_area.x + plot_area.width &&
	   mouse.y >= plot_area.y &&
	   mouse.y <= plot_area.y + plot_area.height {
		best_idx := -1
		best_dist := math.inf_f64(1)
		for a, i in arrows {
			if math.is_nan(a.x) || math.is_nan(a.y) {
				continue
			}
			pt := to_screen(plot_area, x_min, y_min, x_range, y_range, a.x, a.y)
			dx := f64(mouse.x - pt.x)
			dy := f64(mouse.y - pt.y)
			if d := math.sqrt(dx * dx + dy * dy); d < best_dist {
				best_dist = d
				best_idx = i
			}
		}
		if best_idx >= 0 && best_dist < f64(14 * sc) {
			a := arrows[best_idx]
			pt := to_screen(plot_area, x_min, y_min, x_range, y_range, a.x, a.y)
			col := theme.axis_x
			if mag_ok {
				m := math.sqrt(a.u * a.u + a.v * a.v)
				if !math.is_nan(m) {
					col = hue_lookup(mag_lo, mag_hi, m, theme.axis_x, theme.axis_z)
				}
			}
			rl.DrawCircleLines(i32(pt.x), i32(pt.y), 6 * sc, theme.text)
			rl.DrawCircle(i32(pt.x), i32(pt.y), 2 * sc, col)

			lines := [3]string{}
			lines[0] = fmt.tprintf("x=%.4f  y=%.4f", a.x, a.y)
			lines[1] = fmt.tprintf("u=%.4g  v=%.4g", a.u, a.v)
			lines[2] = fmt.tprintf("|v|=%.4g", math.sqrt(a.u * a.u + a.v * a.v))
			draw_tooltip(mouse, plot_area, lines[:], theme, font_size, sc)
		}
	}

	// Save PNG (shared widget, see plot_export.odin).
	if plot_save_button(app, rect, title, theme, sc) {
		plot_export_quiver(
			app,
			X, Y, U, V,
			title,
			x_label,
			y_label,
			rect,
			theme,
			font_size,
			sc,
			scale,
		)
	}

	// Arrow-size multiplier stepper (hidden during offscreen export so its
	// buttons can never catch the click that triggered the save).
	if scale_edit != nil && !app.exporting {
		quiver_scale_stepper(rect, scale_edit, theme, sc)
	}
}

QUIVER_SCALE_MIN :: 0.1
QUIVER_SCALE_MAX :: 20.0
QUIVER_SCALE_STEP :: 1.5

// Draws a small `− N× +` stepper in the top-right corner of a quiver panel
// (mirrors the histogram bin stepper). Multiplicative steps: + scales up by
// QUIVER_SCALE_STEP, − down by the same amount. Mutates `scale`.
quiver_scale_stepper :: proc(rect: rl.Rectangle, scale: ^f32, theme: Theme, sc: f32) {
	btn_size := f32(18 * sc)
	btn_y := rect.y + 2 * sc
	gap := 2 * sc

	label := fmt.tprintf("%g×", scale^)
	label_c := strings.clone_to_cstring(label, context.temp_allocator)
	label_w := f32(measure_text(label_c, i32(11 * sc))) + 10 * sc

	total_w := btn_size * 3 + label_w + gap * 4
	right := rect.x + rect.width - 76 * sc

	minus_rect := rl.Rectangle{right - total_w, btn_y, btn_size, btn_size}
	label_rect := rl.Rectangle{minus_rect.x + minus_rect.width + gap, btn_y, label_w, btn_size}
	plus_rect := rl.Rectangle{label_rect.x + label_rect.width + gap, btn_y, btn_size, btn_size}

	draw_step_btn :: proc(r: rl.Rectangle, sym: cstring, theme: Theme, sc: f32) -> bool {
		mouse := rl.GetMousePosition()
		hover := rl.CheckCollisionPointRec(mouse, r)
		radius := 4 * sc
		draw_fill_rounded(r, theme.hover if hover else theme.bg, radius)
		draw_stroke_rounded(r, theme.border, radius, 1)
		tw := f32(measure_text(sym, i32(11 * sc)))
		draw_text(
			sym,
			i32(r.x + (r.width - tw) * 0.5),
			i32(r.y + (r.height - 11 * sc) * 0.5),
			i32(11 * sc),
			theme.text,
		)
		return hover && rl.IsMouseButtonReleased(.LEFT)
	}

	if draw_step_btn(minus_rect, "-", theme, sc) {
		scale^ = clamp(scale^ / QUIVER_SCALE_STEP, QUIVER_SCALE_MIN, QUIVER_SCALE_MAX)
	}
	if draw_step_btn(plus_rect, "+", theme, sc) {
		scale^ = clamp(scale^ * QUIVER_SCALE_STEP, QUIVER_SCALE_MIN, QUIVER_SCALE_MAX)
	}
	draw_fill_rounded(label_rect, theme.bg, 4 * sc)
	draw_stroke_rounded(label_rect, theme.border, 4 * sc, 1)
	draw_text(
		label_c,
		i32(label_rect.x + (label_rect.width - label_w) * 0.5 + 4 * sc),
		i32(label_rect.y + (label_rect.height - 11 * sc) * 0.5),
		i32(11 * sc),
		theme.text,
	)
}