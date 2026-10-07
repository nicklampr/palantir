package palantir

// Matplotlib-style 2D contour lines over a scalar field. X and Y may be
// compact 1D axes with flattened Z, or row-wise coordinates for a complete
// rectangular grid; no meshgrid-shaped X/Y inputs are required.

import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"
import rl "vendor:raylib"

CONTOUR_LEVEL_COUNT :: 7
CONTOUR_LEVEL_MIN :: 1
CONTOUR_LEVEL_MAX :: 32
CONTOUR_MAX_CELLS :: 50_000

Contour2D_Segment :: struct {
	a, b: [2]f64,
	level: f64,
}

contour2d_add_cell :: proc(
	segments: ^[dynamic]Contour2D_Segment,
	grid: Scalar_Grid_2D,
	ix, ix1, iy, iy1: int,
	level: f64,
) {
	// Clockwise corners, with x-slowest/y-fastest field storage.
	p := [4][2]f64 {
		{grid.x[ix], grid.y[iy]},
		{grid.x[ix1], grid.y[iy]},
		{grid.x[ix1], grid.y[iy1]},
		{grid.x[ix], grid.y[iy1]},
	}
	k := [4]int {
		ix * len(grid.y) + iy,
		ix1 * len(grid.y) + iy,
		ix1 * len(grid.y) + iy1,
		ix * len(grid.y) + iy1,
	}
	v := [4]f64{grid.z[k[0]], grid.z[k[1]], grid.z[k[2]], grid.z[k[3]]}
	if math.is_nan(v[0]) || math.is_nan(v[1]) || math.is_nan(v[2]) || math.is_nan(v[3]) {
		return
	}

	// Crossings are ordered around the cell: bottom, right, top, left.
	crossings := [4][2]f64{}
	ncross := 0
	for edge in 0 ..< 4 {
		next := (edge + 1) % 4
		if (v[edge] < level) == (v[next] < level) {
			continue
		}
		t := (level - v[edge]) / (v[next] - v[edge])
		crossings[ncross] = {
			p[edge][0] + t * (p[next][0] - p[edge][0]),
			p[edge][1] + t * (p[next][1] - p[edge][1]),
		}
		ncross += 1
	}

	if ncross == 2 {
		append(segments, Contour2D_Segment{crossings[0], crossings[1], level})
	} else if ncross == 4 {
		// Resolve saddle cells from the center value (an asymptotic-decider
		// approximation) instead of arbitrarily crossing the contour lines.
		center_high := (v[0] + v[1] + v[2] + v[3]) * 0.25 >= level
		corner0_high := v[0] >= level
		if center_high == corner0_high {
			append(segments, Contour2D_Segment{crossings[0], crossings[1], level})
			append(segments, Contour2D_Segment{crossings[2], crossings[3], level})
		} else {
			append(segments, Contour2D_Segment{crossings[0], crossings[3], level})
			append(segments, Contour2D_Segment{crossings[1], crossings[2], level})
		}
	}
}

contour2d_segments :: proc(grid: Scalar_Grid_2D, level_count: int = CONTOUR_LEVEL_COUNT) -> []Contour2D_Segment {
	if len(grid.x) < 2 || len(grid.y) < 2 || len(grid.z) != len(grid.x) * len(grid.y) {
		return nil
	}
	lo, hi, ok := scalar_grid_range(grid)
	if !ok || same_value(lo, hi) || level_count <= 0 {
		return nil
	}

	cell_count := (len(grid.x) - 1) * (len(grid.y) - 1)
	step := 1
	if cell_count > CONTOUR_MAX_CELLS {
		step = int(math.sqrt(f64(cell_count) / f64(CONTOUR_MAX_CELLS))) + 1
	}
	capacity := min(cell_count * level_count, 4096)
	segments := make([dynamic]Contour2D_Segment, 0, capacity, context.temp_allocator)
	for level_i in 1 ..= level_count {
		level := lo + (hi - lo) * f64(level_i) / f64(level_count + 1)
		ix := 0
		for ix < len(grid.x) - 1 {
			ix1 := min(ix + step, len(grid.x) - 1)
			iy := 0
			for iy < len(grid.y) - 1 {
				iy1 := min(iy + step, len(grid.y) - 1)
				contour2d_add_cell(&segments, grid, ix, ix1, iy, iy1, level)
				iy = iy1
			}
			ix = ix1
		}
	}
	return segments[:]
}

plot_contour :: proc(
	app: ^App,
	X, Y, Z: []f64,
	title, x_label, y_label, z_label: string,
	rect: rl.Rectangle,
	theme: Theme,
	font_size: i32,
	ui_scale: f32 = 1,
	levels: int = CONTOUR_LEVEL_COUNT,
) {
	sc := ui_scale
	draw_fill_rounded(rect, theme.window_bg, UI_RADIUS_SM * sc)
	title_c := strings.clone_to_cstring(title, context.temp_allocator)
	draw_text(title_c, i32(rect.x + 8 * sc), i32(rect.y + 4 * sc), i32(11 * sc), theme.muted)
	if !app.exporting {
		draw_plot_zoom_hint(rect, theme, sc)
	}

	plot_area := plot_area_of(rect, Plot_Layout{70, 26, 40, 22}, sc)
	grid := scalar_grid_from_arrays(X, Y, Z)
	if len(grid.x) < 2 || len(grid.y) < 2 {
		draw_text("No rectangular grid", i32(plot_area.x), i32(plot_area.y), i32(10 * sc), theme.text)
		return
	}
	x_min, x_max := math.inf_f64(1), math.inf_f64(-1)
	y_min, y_max := math.inf_f64(1), math.inf_f64(-1)
	for x in grid.x {
		if math.is_nan(x) {continue}
		x_min, x_max = min(x_min, x), max(x_max, x)
	}
	for y in grid.y {
		if math.is_nan(y) {continue}
		y_min, y_max = min(y_min, y), max(y_max, y)
	}
	z_min, z_max, z_ok := scalar_grid_range(grid)
	if !z_ok {
		draw_text("No finite Z values", i32(plot_area.x), i32(plot_area.y), i32(10 * sc), theme.text)
		return
	}
	if same_value(x_min, x_max) {x_max = x_min + 1}
	if same_value(y_min, y_max) {y_max = y_min + 1}
	if same_value(z_min, z_max) {z_max = z_min + 1}

	x_min, x_max, y_min, y_max = plot_zoom_bounds(
		app,
		PLOT_CONTOUR,
		plot_area,
		x_min,
		x_max,
		y_min,
		y_max,
	)
	x_range, y_range := x_max - x_min, y_max - y_min

	for i in 0 ..= 4 {
		t := f64(i) / 4
		gx, gy := x_min + t * x_range, y_min + t * y_range
		sx := plot_area.x + f32(t) * plot_area.width
		sy := plot_area.y + plot_area.height - f32(t) * plot_area.height
		rl.DrawLine(i32(plot_area.x), i32(sy), i32(plot_area.x + plot_area.width), i32(sy), theme.grid)
		rl.DrawLine(i32(sx), i32(plot_area.y), i32(sx), i32(plot_area.y + plot_area.height), theme.grid)
		x_lbl := strings.clone_to_cstring(fmt.tprintf("%.3g", gx), context.temp_allocator)
		y_lbl := strings.clone_to_cstring(fmt.tprintf("%.3g", gy), context.temp_allocator)
		draw_text(x_lbl, i32(sx - 20 * sc), i32(plot_area.y + plot_area.height + 2 * sc), font_size - 2, theme.text)
		draw_text(y_lbl, i32(plot_area.x - 60 * sc), i32(sy - 8 * sc), font_size - 2, theme.text)
	}
	draw_plot_axis_labels(rect, plot_area, x_label, y_label, theme, font_size, sc)

	segments := contour2d_segments(grid, levels)
	rl.BeginScissorMode(c.int(plot_area.x), c.int(plot_area.y), c.int(plot_area.width), c.int(plot_area.height))
	for s in segments {
		color := hue_lookup(z_min, z_max, s.level, theme.axis_x, theme.axis_z)
		a := rl.Vector2 {
			plot_area.x + f32((s.a[0] - x_min) / x_range) * plot_area.width,
			plot_area.y + plot_area.height - f32((s.a[1] - y_min) / y_range) * plot_area.height,
		}
		b := rl.Vector2 {
			plot_area.x + f32((s.b[0] - x_min) / x_range) * plot_area.width,
			plot_area.y + plot_area.height - f32((s.b[1] - y_min) / y_range) * plot_area.height,
		}
		rl.DrawLineEx(a, b, max(1.0, 1.4 * sc), color)
	}
	rl.EndScissorMode()
	draw_plot_colorbar(rect, plot_area, z_min, z_max, z_label, theme, font_size, sc)

	if plot_save_button(app, rect, title, theme, sc) {
		plot_export_contour(app, X, Y, Z, title, x_label, y_label, z_label, rect, theme, font_size, sc, levels)
	}
}
