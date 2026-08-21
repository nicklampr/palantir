package palantir

// Earth map widget: a pan/zoomable Web-Mercator view of the world with a
// Natural Earth II raster background and one or more routes drawn from
// []PerformanceResult with hover tooltips and a legend.
//
// The raster is embedded at compile time via `#load` (an equirectangular PNG,
// re-projected to Web Mercator once on first use) and drawn as a single
// full-resolution texture with GPU mipmaps, so the sharpest available detail is
// shown at every zoom. The projection and pan/zoom state live in `Map_View` so
// the map can later host weather overlays.
//
// Adapted from yggdrasil/earth_map.odin; the data model here is palantir's own
// generic PerformanceResult (results.odin) so any file with lat/lon columns
// can be drawn as a route.

import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import rl "vendor:raylib"

MAP_ZOOM_MIN :: 1.0 // min lon span in degrees (max zoom-in)
MAP_ZOOM_MAX :: 360.0 // max lon span (whole world)

// Equirectangular (8192x4096) Natural Earth II shaded-relief + water image.
// PNG is used because this raylib build has no JPEG/TIFF decoder.
EARTH_BG_PNG := #load("ne_earth_bg.png")

// Square Web-Mercator background texture size (covers lat ±85.05).
MAP_BG_SIZE :: 8192

// Rows of the master reprojection are filled by this many worker threads.
BG_REPRO_THREADS :: 4

earthmap_margins := Plot_Layout{12, 26, 12, 12}

// --- data structures -------------------------------------------------------

// One route on the map. Points come from the dataset's sampled map cache; the
// hover tooltip reads values back from the original columns at each point's row
// index, so any dataset with lat/lon columns can be drawn without a hardcoded
// row type.
PlotRoute :: struct {
	name:  string,
	color: rl.Color,
	ds:    ^Dataset,
	cache: ^Map_Cache,
}

// Persistent pan/zoom state of the map view.
Map_View :: struct {
	center_lon: f32,
	center_lat: f32,
	lon_span:   f32, // degrees of longitude visible
	panning:    bool,
	// Which mouse button started the current pan (LEFT or MIDDLE).
	pan_button: rl.MouseButton,
}

// Raster background: the full-world Mercator texture (with GPU mipmaps).
Map_Background :: struct {
	tex: rl.Texture2D,
}

// --- projection ------------------------------------------------------------

// Normalized Web-Mercator world coords in [0,1]; y grows downward.
map_world :: proc(lon, lat: f32) -> [2]f32 {
	x := (lon + 180) / 360
	y := mercator_y_from_lat(lat)
	yn := 0.5 - y / (2 * f32(math.PI))
	return [2]f32{x, yn}
}

lat_from_world_y :: proc(wy: f32) -> f32 {
	y := (0.5 - wy) * 2 * f32(math.PI)
	return lat_from_mercator_y(y)
}

// Per-frame view geometry: world-space edges + padded cull rect.
Map_Geom :: struct {
	plot:                                         rl.Rectangle,
	span_x, span_y:                               f32,
	left, top, right, bottom:                     f32, // view edges (world coords)
	cull_left, cull_right, cull_top, cull_bottom: f32, // padded for edge clipping
}

map_geom :: proc(view: Map_View, plot: rl.Rectangle) -> Map_Geom {
	center := map_world(view.center_lon, view.center_lat)
	span_x := view.lon_span / 360
	span_y := span_x * (plot.height / plot.width)
	pad_x := span_x * 0.15
	pad_y := span_y * 0.15
	return Map_Geom {
		plot = plot,
		span_x = span_x,
		span_y = span_y,
		left = center.x - span_x * 0.5,
		right = center.x + span_x * 0.5,
		top = center.y - span_y * 0.5,
		bottom = center.y + span_y * 0.5,
		cull_left = center.x - span_x * 0.5 - pad_x,
		cull_right = center.x + span_x * 0.5 + pad_x,
		cull_top = center.y - span_y * 0.5 - pad_y,
		cull_bottom = center.y + span_y * 0.5 + pad_y,
	}
}

// Project a world-space point to screen; ok is false when outside the
// padded cull rect.  Used for per-point hover detection and polyline
// drawing — segments whose ends are both outside are skipped.
map_project :: proc(g: Map_Geom, lon, lat: f32) -> (sx, sy: f32, ok: bool) {
	w := map_world(lon, lat)
	if w.x < g.cull_left || w.x > g.cull_right || w.y < g.cull_top || w.y > g.cull_bottom {
		return 0, 0, false
	}
	sx = g.plot.x + (w.x - g.left) / g.span_x * g.plot.width
	sy = g.plot.y + (w.y - g.top) / g.span_y * g.plot.height
	return sx, sy, true
}

// --- input (pan / zoom) ----------------------------------------------------

handle_map_input :: proc(view: ^Map_View, plot: rl.Rectangle, input_enabled: bool) {
	if !input_enabled {
		view.panning = false
		return
	}
	mouse := rl.GetMousePosition()
	over := rl.CheckCollisionPointRec(mouse, plot)

	if over && ctrl_held() {
		wheel := rl.GetMouseWheelMove()
		if wheel != 0 {
			zoom_map(view, plot, mouse, wheel)
		}
	}

	if rl.IsMouseButtonPressed(.LEFT) || rl.IsMouseButtonPressed(.MIDDLE) {
		if over {
			view.panning = true
			view.pan_button = .LEFT if rl.IsMouseButtonPressed(.LEFT) else .MIDDLE
		}
	}
	if view.panning {
		if rl.IsMouseButtonDown(view.pan_button) {
			pan_map(view, plot, rl.GetMouseDelta())
		} else {
			view.panning = false
		}
	}
}

zoom_map :: proc(view: ^Map_View, plot: rl.Rectangle, mouse: rl.Vector2, wheel: f32) {
	// keep the world point under the cursor fixed while changing the span
	lon, lat := map_screen_to_world(view^, plot, mouse.x, mouse.y)
	view.lon_span *= math.pow(1.25, -wheel)
	view.lon_span = clamp(view.lon_span, MAP_ZOOM_MIN, MAP_ZOOM_MAX)

	g := map_geom(view^, plot)
	center := map_world(lon, lat)
	fx := (mouse.x - plot.x) / plot.width
	fy := (mouse.y - plot.y) / plot.height
	view.center_lon = (center.x - fx * g.span_x + g.span_x * 0.5) * 360 - 180
	view.center_lat = lat_from_world_y(center.y - fy * g.span_y + g.span_y * 0.5)
	clamp_map_view(view)
}

pan_map :: proc(view: ^Map_View, plot: rl.Rectangle, delta: rl.Vector2) {
	g := map_geom(view^, plot)
	center := map_world(view.center_lon, view.center_lat)
	center.x -= delta.x / plot.width * g.span_x
	center.y -= delta.y / plot.height * g.span_y
	view.center_lon = center.x * 360 - 180
	view.center_lat = lat_from_world_y(center.y)
	clamp_map_view(view)
}

clamp_map_view :: proc(view: ^Map_View) {
	view.center_lon = clamp(view.center_lon, -180, 180)
	view.center_lat = clamp(view.center_lat, -85, 85)
}

map_screen_to_world :: proc(view: Map_View, plot: rl.Rectangle, sx, sy: f32) -> (lon, lat: f32) {
	g := map_geom(view, plot)
	fx := (sx - plot.x) / plot.width
	fy := (sy - plot.y) / plot.height
	wx := g.left + fx * g.span_x
	wy := g.top + fy * g.span_y
	lon = wx * 360 - 180
	lat = lat_from_world_y(wy)
	return
}

mercator_y_from_lat :: proc(lat: f32) -> f32 {
	lat_r := lat * f32(math.PI) / 180.0
	return math.ln(math.tan(f32(math.PI) / 4.0 + lat_r / 2.0))
}

lat_from_mercator_y :: proc(y: f32) -> f32 {
	return 180.0 / f32(math.PI) * (2.0 * math.atan(math.exp(y)) - f32(math.PI) / 2.0)
}

// --- background imagery ----------------------------------------------------

// Row range of the master Mercator reprojection that one worker thread fills.
BG_Repro_Range :: struct {
	src:    [^]rl.Color, // flat RGBA source (equirectangular)
	dst:    [^]rl.Color, // master Mercator buffer
	sw, sh: f32, // source dimensions
	xstep:  f32, // source u advance per output column
	row_lo: int,
	row_hi: int, // exclusive
}

// Reprojects rows [row_lo, row_hi) of the source image onto the Web-Mercator
// grid. Each row writes a disjoint slice of dst, so ranges can run in parallel.
bg_reproject_rows :: proc(w: ^BG_Repro_Range) {
	lerp :: proc(a, b, t: f32) -> f32 {
		return a + (b - a) * t
	}
	for row in w.row_lo ..< w.row_hi {
		wy := f32(row) / f32(MAP_BG_SIZE - 1)
		lat := lat_from_world_y(wy)
		// vsrc is the source (equirectangular) v for this Mercator row; the
		// two source rows and the y-fraction are constant across the row.
		yf := clamp((90.0 - lat) / 180.0, 0, 1) * (w.sh - 1)
		y0 := int(yf)
		y1 := min(y0 + 1, int(w.sh) - 1)
		fy := yf - f32(y0)
		inv_fy := 1 - fy
		r0 := y0 * int(w.sw)
		r1 := y1 * int(w.sw)
		base := row * MAP_BG_SIZE
		for col in 0 ..< MAP_BG_SIZE {
			xf := f32(col) * w.xstep
			x0 := int(xf)
			x1 := min(x0 + 1, int(w.sw) - 1)
			fx := xf - f32(x0)
			c00 := w.src[r0 + x0]
			c01 := w.src[r0 + x1]
			c10 := w.src[r1 + x0]
			c11 := w.src[r1 + x1]
			r := lerp(f32(c00.r), f32(c01.r), fx) * inv_fy + lerp(f32(c10.r), f32(c11.r), fx) * fy
			g := lerp(f32(c00.g), f32(c01.g), fx) * inv_fy + lerp(f32(c10.g), f32(c11.g), fx) * fy
			b := lerp(f32(c00.b), f32(c01.b), fx) * inv_fy + lerp(f32(c10.b), f32(c11.b), fx) * fy
			a := lerp(f32(c00.a), f32(c01.a), fx) * inv_fy + lerp(f32(c10.a), f32(c11.a), fx) * fy
			w.dst[base + col] = rl.Color{u8(r + 0.5), u8(g + 0.5), u8(b + 0.5), u8(a + 0.5)}
		}
	}
}

// Worker entry used by the thread API (receives a raw BG_Repro_Range pointer).
bg_reproject_rows_data :: proc(data: rawptr) {
	bg_reproject_rows((^BG_Repro_Range)(data))
}

// Loads the embedded equirectangular world image, re-projects it onto a square
// Web-Mercator grid (rows match map_world's y axis, filled in parallel) and
// uploads it as a texture with GPU mipmaps. Returns true on success.
load_map_background :: proc(out: ^Map_Background) -> bool {
	if out.tex.id != 0 {
		return true
	}
	img := rl.LoadImageFromMemory(".png", raw_data(EARTH_BG_PNG), c.int(len(EARTH_BG_PNG)))
	if img.data == nil {
		return false
	}
	defer rl.UnloadImage(img)

	src := rl.LoadImageColors(img) // flat RGBA copy, any source format
	if src == nil {
		return false
	}
	defer rl.UnloadImageColors(src)

	master := rl.GenImageColor(MAP_BG_SIZE, MAP_BG_SIZE, rl.Color{0, 0, 0, 255})
	defer rl.UnloadImage(master)
	dst := ([^]rl.Color)(master.data)

	sw := f32(img.width)
	sh := f32(img.height)
	xstep := (sw - 1) / f32(MAP_BG_SIZE - 1)

	rows_per_thread := MAP_BG_SIZE / BG_REPRO_THREADS
	// Fixed arrays keep the worker ranges alive until all threads are joined
	// (temp-allocated slices caused worker access violations here).
	ranges: [BG_REPRO_THREADS]BG_Repro_Range
	threads: [BG_REPRO_THREADS]^thread.Thread
	spawned := 0
	for i in 0 ..< BG_REPRO_THREADS {
		row_lo := i * rows_per_thread
		row_hi :=
			(i + 1) * rows_per_thread if i == BG_REPRO_THREADS - 1 else row_lo + rows_per_thread
		ranges[i] = BG_Repro_Range {
			src    = src,
			dst    = dst,
			sw     = sw,
			sh     = sh,
			xstep  = xstep,
			row_lo = row_lo,
			row_hi = row_hi,
		}
		if t := thread.create_and_start_with_data(rawptr(&ranges[i]), bg_reproject_rows_data);
		   t != nil {
			threads[spawned] = t
			spawned += 1
		} else {
			bg_reproject_rows(&ranges[i]) // failed to spawn: fill this range inline
		}
	}
	for i in 0 ..< spawned {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	out.tex = rl.LoadTextureFromImage(master)
	rl.GenTextureMipmaps(&out.tex)
	rl.SetTextureFilter(out.tex, .TRILINEAR)
	return out.tex.id != 0
}

destroy_map_background :: proc(bg: ^Map_Background) {
	if bg.tex.id != 0 {
		rl.UnloadTexture(bg.tex)
		bg.tex = rl.Texture2D{}
	}
}

// Draws the raster background covering the visible view. Texture UVs equal the
// world coordinates (u=x, v=map_world y), so the visible sub-rect maps to a
// texture sub-rect directly. The view is drawn in one quad per wrapped
// longitude segment so both sides of the dateline stay filled at max zoom-out.
draw_map_background :: proc(g: Map_Geom, bg: ^Map_Background) {
	tex := bg.tex
	if tex.id == 0 {
		return
	}
	v0 := clamp(g.top, 0.0, 1.0)
	v1 := clamp(g.bottom, 0.0, 1.0)
	if v1 <= v0 {
		return
	}
	k0 := int(math.floor(g.left))
	k1 := int(math.floor(g.right))
	for k in k0 ..= k1 {
		sx0 := max(g.left, f32(k))
		sx1 := min(g.right, f32(k) + 1)
		if sx1 <= sx0 {
			continue
		}
		px0 := g.plot.x + (sx0 - g.left) / g.span_x * g.plot.width
		px1 := g.plot.x + (sx1 - g.left) / g.span_x * g.plot.width
		py0 := g.plot.y + (v0 - g.top) / g.span_y * g.plot.height
		py1 := g.plot.y + (v1 - g.top) / g.span_y * g.plot.height

		u0 := sx0 - f32(k)
		u1 := sx1 - f32(k)
		src_rect := rl.Rectangle {
			x      = u0 * f32(tex.width),
			y      = v0 * f32(tex.height),
			width  = (u1 - u0) * f32(tex.width),
			height = (v1 - v0) * f32(tex.height),
		}
		dst_rect := rl.Rectangle {
			x      = px0,
			y      = py0,
			width  = px1 - px0,
			height = py1 - py0,
		}
		rl.DrawTexturePro(tex, src_rect, dst_rect, {0, 0}, 0, rl.WHITE)
	}
}

// --- drawing ---------------------------------------------------------------

draw_routes :: proc(routes: []PlotRoute, view: Map_View, plot: rl.Rectangle, sc: f32) {
	g := map_geom(view, plot)
	core_w := 2.5 * sc
	halo_w := core_w * 3.2
	for route in routes {
		prev_ok := false
		prev_sx, prev_sy: f32
		started := false
		last_ok := false
		last_sx, last_sy: f32
		for pi in 0 ..< len(route.cache.lat) {
			sx, sy, ok := map_project(g, f32(route.cache.lon[pi]), f32(route.cache.lat[pi]))
			if !ok {
				prev_ok = false
				continue
			}
			if !started {
				// glow cap on the route start
				rl.DrawCircleV(rl.Vector2{sx, sy}, halo_w * 0.5, rl.Fade(route.color, 0.28))
				started = true
			}
			if prev_ok {
				start := rl.Vector2{prev_sx, prev_sy}
				end := rl.Vector2{sx, sy}
				rl.DrawLineEx(start, end, halo_w, rl.Fade(route.color, 0.28))
				rl.DrawLineEx(start, end, core_w, route.color)
			}
			// round the core joins and cap the line
			rl.DrawCircleV(rl.Vector2{sx, sy}, core_w * 0.5, route.color)
			prev_sx, prev_sy = sx, sy
			prev_ok = true
			last_ok = true
			last_sx, last_sy = sx, sy
		}
		if last_ok {
			// glow cap on the route end
			rl.DrawCircleV(rl.Vector2{last_sx, last_sy}, halo_w * 0.5, rl.Fade(route.color, 0.28))
		}
	}
}

draw_legend :: proc(
	routes: []PlotRoute,
	plot: rl.Rectangle,
	theme: Theme,
	font_size: i32,
	sc: f32,
) {
	if len(routes) == 0 {
		return
	}
	fs := f32(font_size)
	max_w: f32 = 0
	names := make([]cstring, len(routes), context.temp_allocator)
	for r, i in routes {
		names[i] = strings.clone_to_cstring(r.name, context.temp_allocator)
		max_w = max(max_w, rl.MeasureTextEx(app_font, names[i], fs, 1).x)
	}
	pad := f32(8 * sc)
	row_h := fs + 6 * sc
	box_w := max_w + 18 * sc + pad * 2
	box_h := row_h * f32(len(routes)) + pad * 2

	bx := plot.x + 8 * sc
	by := plot.y + 8 * sc
	box := rl.Rectangle{bx, by, box_w, box_h}
	draw_fill_rounded(box, rl.Fade(theme.bg, 0.92), UI_RADIUS_SM * sc)
	draw_stroke_rounded(box, theme.border, UI_RADIUS_SM * sc, 1)

	for _, i in routes {
		y := by + pad + f32(i) * row_h
		swatch := rl.Rectangle{bx + pad, y, 12 * sc, 12 * sc}
		draw_fill_rounded(swatch, routes[i].color, 3)
		rl.DrawTextEx(
			app_font,
			names[i],
			rl.Vector2{bx + pad + 18 * sc, y},
			fs,
			1,
			theme.text,
		)
	}
}

draw_map_hint :: proc(plot: rl.Rectangle, theme: Theme, font_size: i32, sc: f32) {
	hint_cstr := strings.clone_to_cstring("drag or middle-drag: pan · ctrl+wheel: zoom", context.temp_allocator)
	draw_text(
		hint_cstr,
		i32(plot.x + 8 * sc),
		i32(plot.y + plot.height - 20 * sc),
		font_size - 2,
		theme.muted,
	)
}

// --- main entry ------------------------------------------------------------

plot_earth_map :: proc(
	app: ^App,
	routes: []PlotRoute,
	view: ^Map_View,
	bg: ^Map_Background,
	title: string,
	rect: rl.Rectangle,
	theme: Theme,
	font_size: i32,
	ui_scale: f32 = 1,
	input_enabled: bool = true,
) {
	sc := ui_scale
	draw_fill_rounded(rect, theme.window_bg, UI_RADIUS_SM * sc)

	title_cstr := strings.clone_to_cstring(title, context.temp_allocator)
	draw_text(title_cstr, i32(rect.x + 8 * sc), i32(rect.y + 4 * sc), i32(11 * sc), theme.muted)

	plot_area := plot_area_of(rect, earthmap_margins, sc)

	// Don't let an offscreen export pass consume pan/zoom or draw hover UI.
	if !app.exporting {
		handle_map_input(view, plot_area, input_enabled)
	}

	// clip to the map area so panned/zoomed content stays inside
	rl.BeginScissorMode(
		c.int(plot_area.x),
		c.int(plot_area.y),
		c.int(plot_area.width),
		c.int(plot_area.height),
	)
	draw_map_background(map_geom(view^, plot_area), bg)
	draw_routes(routes, view^, plot_area, sc)
	rl.EndScissorMode()

	draw_legend(routes, plot_area, theme, font_size, sc)
	draw_map_hint(plot_area, theme, font_size, sc)

	if !app.exporting {
		draw_map_hover_tooltip(routes, view^, plot_area, theme, font_size, sc)
	}

	if plot_save_button(app, rect, title, theme, sc) {
		plot_export_earth_map(app, routes, view, bg, title, rect, theme, font_size, sc)
	}
}

// Finds the route point nearest the mouse (within a threshold) and shows a
// tooltip with the route name, position, time, and the auto-detected columns
// at that row.
draw_map_hover_tooltip :: proc(
	routes: []PlotRoute,
	view: Map_View,
	plot: rl.Rectangle,
	theme: Theme,
	font_size: i32,
	sc: f32,
) {
	if len(routes) == 0 {
		return
	}
	mouse := rl.GetMousePosition()
	if !rl.CheckCollisionPointRec(mouse, plot) {
		return
	}

	g := map_geom(view, plot)
	threshold := f64(10 * sc)
	best_route := -1
	best_pt := -1
	best_dist := math.inf_f64(1)

	for ri in 0 ..< len(routes) {
		cache := routes[ri].cache
		for pi in 0 ..< len(cache.lat) {
			sx, sy, ok := map_project(g, f32(cache.lon[pi]), f32(cache.lat[pi]))
			if !ok {continue}
			dx := f64(mouse.x - sx)
			dy := f64(mouse.y - sy)
			d := math.sqrt(dx * dx + dy * dy)
			if d < best_dist {
				best_dist = d
				best_route = ri
				best_pt = pi
			}
		}
	}

	if best_route < 0 || best_dist > threshold {
		return
	}

	route := &routes[best_route]
	cache := route.cache
	row := cache.rows[best_pt]

	lines := make([dynamic]string, 0, 8, context.temp_allocator)
	append(&lines, fmt.tprintf("%s", route.name))
	append(&lines, fmt.tprintf("lat %.4f  lon %.4f", cache.lat[best_pt], cache.lon[best_pt]))

	if t := cache.time[best_pt]; !math.is_nan(t) {
		dt, _ := time.time_to_datetime(time.unix(i64(t), 0))
		append(&lines, fmt.tprintf(
			"%04d-%02d-%02d %02d:%02d",
			dt.year,
			dt.month,
			dt.day,
			dt.hour,
			dt.minute,
		))
	}

	for ci, i in cache.cols {
		if i >= MAX_TOOLTIP_COLS {
			append(&lines, fmt.tprintf("+%d more columns", len(cache.cols) - MAX_TOOLTIP_COLS))
			break
		}
		col := &route.ds.columns[ci]
		cell := format_cell(col, row)
		if len(cell) == 0 {
			continue
		}
		append(&lines, fmt.tprintf("%s: %s", col.name, cell))
	}
	draw_tooltip(mouse, plot, lines[:], theme, font_size, sc)
}

// Cap on tooltip columns so a wide dataset does not produce a giant popup.
MAX_TOOLTIP_COLS :: 6

@(test)
test_map_projection_roundtrip :: proc(t: ^testing.T) {
	view := Map_View {
		center_lon = 10,
		center_lat = 40,
		lon_span   = 60,
	}
	plot := rl.Rectangle{100, 50, 800, 500}

	probe := [][2]f32{{10, 40}, {20, 30}, {0, 50}, {-5, 10}}
	for pt in probe {
		lon, lat := pt[0], pt[1]
		sx, sy, ok := map_project(map_geom(view, plot), lon, lat)
		if !ok {continue}
		rlon, rlat := map_screen_to_world(view, plot, sx, sy)
		testing.expect(
			t,
			math.abs(rlon - lon) < 1e-2,
			fmt.tprintf("lon roundtrip: %v -> %v", lon, rlon),
		)
		testing.expect(
			t,
			math.abs(rlat - lat) < 1e-2,
			fmt.tprintf("lat roundtrip: %v -> %v", lat, rlat),
		)
	}

	// world <-> lat inverse
	lats := [5]f32{-80, -30, 0, 30, 80}
	for lat in lats {
		w := map_world(0, lat)
		rlat := lat_from_world_y(w[1])
		testing.expect(
			t,
			math.abs(rlat - lat) < 1e-2,
			fmt.tprintf("lat inverse: %v -> %v", lat, rlat),
		)
	}
}