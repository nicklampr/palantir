package palantir

// 3D wireframe surface viewer. It uses the same fly camera, Z-up convention,
// offscreen viewport, ground grid and axis markers as the mesh/quiver views.

import "core:c"
import "core:math"
import "core:strings"
import rl "vendor:raylib"

WIREFRAME_MAX_LINES_PER_AXIS :: 100

wireframe_axis_step :: proc(n: int) -> int {
	return max(1, (n + WIREFRAME_MAX_LINES_PER_AXIS - 1) / WIREFRAME_MAX_LINES_PER_AXIS)
}

wireframe_draw_grid :: proc(grid: Scalar_Grid_2D, color: rl.Color) {
	sx := wireframe_axis_step(len(grid.x))
	sy := wireframe_axis_step(len(grid.y))

	// Curves for fixed X (running over Y). Include the final row even when
	// the decimation stride does not land on its index.
	ix := 0
	for ix < len(grid.x) {
		for iy := 0; iy < len(grid.y) - 1; iy += sy {
			j := min(iy + sy, len(grid.y) - 1)
			z0 := grid.z[ix * len(grid.y) + iy]
			z1 := grid.z[ix * len(grid.y) + j]
			if math.is_nan(grid.x[ix]) || math.is_nan(grid.y[iy]) || math.is_nan(grid.y[j]) || math.is_nan(z0) || math.is_nan(z1) {
				continue
			}
			rl.DrawLine3D(
				rl.Vector3{f32(grid.x[ix]), f32(grid.y[iy]), f32(z0)},
				rl.Vector3{f32(grid.x[ix]), f32(grid.y[j]), f32(z1)},
				color,
			)
		}
		if ix == len(grid.x) - 1 {break}
		ix = min(ix + sx, len(grid.x) - 1)
	}

	// Curves for fixed Y (running over X), also including the final column.
	iy := 0
	for iy < len(grid.y) {
		for ix := 0; ix < len(grid.x) - 1; ix += sx {
			j := min(ix + sx, len(grid.x) - 1)
			z0 := grid.z[ix * len(grid.y) + iy]
			z1 := grid.z[j * len(grid.y) + iy]
			if math.is_nan(grid.x[ix]) || math.is_nan(grid.x[j]) || math.is_nan(grid.y[iy]) || math.is_nan(z0) || math.is_nan(z1) {
				continue
			}
			rl.DrawLine3D(
				rl.Vector3{f32(grid.x[ix]), f32(grid.y[iy]), f32(z0)},
				rl.Vector3{f32(grid.x[j]), f32(grid.y[iy]), f32(z1)},
				color,
			)
		}
		if iy == len(grid.y) - 1 {break}
		iy = min(iy + sy, len(grid.y) - 1)
	}
}

draw_wireframe_view :: proc(
	app: ^App,
	grid: Scalar_Grid_2D,
	title: string,
	rect: rl.Rectangle,
	theme: Theme,
	sc: f32,
) {
	rs := &app.results
	mv := &rs.wireframe_view
	minp, maxp, bounds_ok := scalar_grid_bounds_3d(grid)
	if !bounds_ok {
		draw_fill_rounded(rect, theme.window_bg, UI_RADIUS_SM * sc)
		draw_text("No finite Z values", c.int(rect.x + 14 * sc), c.int(rect.y + 14 * sc), i32(13 * sc), theme.muted)
		return
	}
	if mv.fit {
		view_fit_bounds(mv, minp, maxp)
		mv.fit = false
	}
	active := !app.palette.open && !rs.dock_resize_input && !results_any_dropdown_open(rs)
	mesh_view_update(mv, rect, active)

	cam := rl.Camera3D {
		position   = mv.pos,
		target     = v3_add(mv.pos, cam_forward(mv.yaw, mv.pitch)),
		up         = {0, 0, 1},
		fovy       = 45,
		projection = .PERSPECTIVE,
	}
	axis_origin := rl.Vector3{f32(minp[0]), f32(minp[1]), f32(minp[2])}
	diag := v3_len(v3_sub(rl.Vector3{f32(maxp[0]), f32(maxp[1]), f32(maxp[2])}, axis_origin))
	axis_len := max(diag * 0.2, 0.1)

	dpi := rl.GetWindowScaleDPI()
	px := max(dpi.x, dpi.y, 1.0)
	w := c.int(max(rect.width * px, 1))
	h := c.int(max(rect.height * px, 1))
	if mv.rt.id == 0 || mv.rt_w != w || mv.rt_h != h {
		if mv.rt.id != 0 {
			rl.UnloadRenderTexture(mv.rt)
		}
		mv.rt = rl.LoadRenderTexture(w, h)
		mv.rt_w = w
		mv.rt_h = h
	}

	rl.BeginTextureMode(mv.rt)
	rl.ClearBackground(theme.window_bg)
	rl.BeginMode3D(cam)
	draw_ground_grid(20, 1.0)
	draw_3d_axis_arrows(axis_origin, axis_len)
	wireframe_draw_grid(grid, theme.accent)
	rl.EndMode3D()
	rl.EndTextureMode()

	src := rl.Rectangle{0, 0, f32(mv.rt.texture.width), -f32(mv.rt.texture.height)}
	rl.DrawTexturePro(mv.rt.texture, src, rect, rl.Vector2{0, 0}, 0, rl.WHITE)
	draw_3d_axis_labels(cam, axis_origin, axis_len, mv.rt.texture.width, mv.rt.texture.height, rect, sc)

	title_c := strings.clone_to_cstring(title, context.temp_allocator)
	draw_text(title_c, i32(rect.x + 8 * sc), i32(rect.y + 4 * sc), i32(11 * sc), theme.muted)
	hint := strings.clone_to_cstring("WASD move · right-drag look · wheel speed", context.temp_allocator)
	draw_text(hint, c.int(rect.x + 8 * sc), c.int(rect.y + 22 * sc), i32(11 * sc), theme.muted)
}
