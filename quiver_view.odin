package palantir

// 3D quiver (vector field) plot, reusing the mesh viewer's fly camera and
// offscreen render-texture infrastructure.
//
// Position/component arrays may be given in either of two forms, detected
// automatically (see quiver3d_from_arrays):
//   - scattered: arrow k sits at (X[k], Y[k], Z[k]) with components
//     (U[k], V[k], W[k]); arrays are independent, may differ in length, and
//     are paired by index (effective count = the min across them).
//   - regular grid: X/Y/Z are the compact coordinate axes (lengths nx/ny/nz)
//     and U/V/W are their flattened product (len = nx*ny*nz, x-slowest order).
//
// Arrows are drawn in world units (true data length) × a user `scale`
// multiplier; the camera fits the tail + scaled-head bounding box and the
// arrows are colored by magnitude.

import "core:c"
import "core:math"
import "core:strings"
import rl "vendor:raylib"

Quiver3D :: struct {
	x, y, z: f64, // tail position
	u, v, w: f64, // vector components
}

// Turns the six arrays into arrows. When U/V/W are the flattened product of
// the compact X/Y/Z axes (len == nx*ny*nz) the grid is expanded in x-slowest
// order (ix outer, iz inner — the order prop3D flattens with); otherwise the
// arrays are index-paired and the result is as long as the shortest input.
quiver3d_from_arrays :: proc(X, Y, Z, U, V, W: []f64) -> []Quiver3D {
	nx := valid_prefix_len(X)
	ny := valid_prefix_len(Y)
	nz := valid_prefix_len(Z)
	field := nx * ny * nz
	if nx >= 1 && ny >= 1 && nz >= 1 && len(U) == field && len(V) == field && len(W) == field {
		out := make([]Quiver3D, field, context.temp_allocator)
		k := 0
		for ix in 0 ..< nx {
			for iy in 0 ..< ny {
				for iz in 0 ..< nz {
					out[k] = Quiver3D{x = X[ix], y = Y[iy], z = Z[iz], u = U[k], v = V[k], w = W[k]}
					k += 1
				}
			}
		}
		return out
	}
	n := min(len(X), len(Y), len(Z), len(U), len(V), len(W))
	out := make([]Quiver3D, n, context.temp_allocator)
	for i in 0 ..< n {
		out[i] = Quiver3D{x = X[i], y = Y[i], z = Z[i], u = U[i], v = V[i], w = W[i]}
	}
	return out
}

quiver3d_magnitude_range :: proc(arrows: []Quiver3D) -> (lo, hi: f64, ok: bool) {
	lo = math.inf_f64(1)
	hi = math.inf_f64(-1)
	for a in arrows {
		if math.is_nan(a.u) || math.is_nan(a.v) || math.is_nan(a.w) {
			continue
		}
		m := math.sqrt(a.u * a.u + a.v * a.v + a.w * a.w)
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

// Bounds covering both tails and heads, NaN-safe. `ok` is false when no arrow
// has finite values.
quiver3d_bounds :: proc(arrows: []Quiver3D) -> (minp, maxp: [3]f64, ok: bool) {
	return quiver3d_fit_bounds(arrows, 1)
}

// Bounds over tails and scale-scaled heads, used to frame the drawn arrows
// (whose heads are pulled back/out by `scale`).
quiver3d_fit_bounds :: proc(arrows: []Quiver3D, scale: f64) -> (minp, maxp: [3]f64, ok: bool) {
	minp = {math.inf_f64(1), math.inf_f64(1), math.inf_f64(1)}
	maxp = {math.inf_f64(-1), math.inf_f64(-1), math.inf_f64(-1)}
	for a in arrows {
		if math.is_nan(a.x) || math.is_nan(a.y) || math.is_nan(a.z) ||
		   math.is_nan(a.u) || math.is_nan(a.v) || math.is_nan(a.w) {
			continue
		}
		minp[0] = min(minp[0], a.x, a.x + a.u * scale)
		maxp[0] = max(maxp[0], a.x, a.x + a.u * scale)
		minp[1] = min(minp[1], a.y, a.y + a.v * scale)
		maxp[1] = max(maxp[1], a.y, a.y + a.v * scale)
		minp[2] = min(minp[2], a.z, a.z + a.w * scale)
		maxp[2] = max(maxp[2], a.z, a.z + a.w * scale)
		ok = true
	}
	return
}

// Draws the 3D quiver plot inside `rect`. X/Y/Z are the arrow tails and U/V/W
// the vector components (see quiver3d_from_arrays for the grid/scattered
// forms). `scale` is the live arrow-size multiplier shown in the stepper.
draw_quiver_view :: proc(
	app: ^App,
	X, Y, Z, U, V, W: []f64,
	scale: ^f32,
	title: string,
	rect: rl.Rectangle,
	theme: Theme,
	sc: f32,
) {
	rs := &app.results
	mv := &rs.quiver_view
	arrows := quiver3d_from_arrays(X, Y, Z, U, V, W)
	s := scale^
	if s <= 0 {
		s = 1
	}

	if mv.fit {
		if minp, maxp, ok := quiver3d_fit_bounds(arrows, f64(s)); ok {
			view_fit_bounds(mv, minp, maxp)
		}
		mv.fit = false
	}

	// Bounds of the drawn (scale-scaled) field, reused for the camera fit and
	// the axis-direction arrows.
	minp, maxp, bounds_ok := quiver3d_fit_bounds(arrows, f64(s))

	active := !app.palette.open && !results_any_dropdown_open(&app.results)
	mesh_view_update(mv, rect, active)

	cam := rl.Camera3D {
		position   = mv.pos,
		target     = v3_add(mv.pos, cam_forward(mv.yaw, mv.pitch)),
		up         = {0, 1, 0},
		fovy       = 45,
		projection = .PERSPECTIVE,
	}

	// Axis-direction arrows at the data's min corner, sized to the bbox.
	axis_origin := rl.Vector3{}
	axis_len := f32(0)
	if bounds_ok {
		axis_origin = rl.Vector3{f32(minp[0]), f32(minp[1]), f32(minp[2])}
		diag := v3_len(v3_sub(rl.Vector3{f32(maxp[0]), f32(maxp[1]), f32(maxp[2])}, axis_origin))
		axis_len = diag * 0.2
		if axis_len <= 0 {
			axis_len = 1
		}
	}

	// Render the 3D scene into an offscreen target sized to the plot rect, then
	// blit it (same approach as the mesh viewer).
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

	mag_lo, mag_hi, mag_ok := quiver3d_magnitude_range(arrows)

	rl.BeginTextureMode(mv.rt)
	rl.ClearBackground(theme.window_bg)
	rl.BeginMode3D(cam)

	rl.DrawGrid(20, 1.0)

	draw_3d_axis_arrows(axis_origin, axis_len)

	for a in arrows {
		if math.is_nan(a.x) || math.is_nan(a.y) || math.is_nan(a.z) ||
		   math.is_nan(a.u) || math.is_nan(a.v) || math.is_nan(a.w) {
			continue
		}
		tail := rl.Vector3{f32(a.x), f32(a.y), f32(a.z)}
		// Head pulled back/out by the user size multiplier.
		head := rl.Vector3{f32(a.x + a.u * f64(s)), f32(a.y + a.v * f64(s)), f32(a.z + a.w * f64(s))}

		col := theme.axis_x
		if mag_ok {
			m := math.sqrt(a.u * a.u + a.v * a.v + a.w * a.w)
			if !math.is_nan(m) {
				col = hue_lookup(mag_lo, mag_hi, m, theme.axis_x, theme.axis_z)
			}
		}

		// Shaft.
		rl.DrawLine3D(tail, head, col)

		// Cone arrowhead at the tip, sized relative to the drawn shaft length.
		dir := v3_sub(head, tail)
		l := v3_len(dir)
		if l > 0 {
			head_len := f32(min(f64(l) * 0.25, 0.6 * f64(s)))
			base := v3_sub(head, v3_scale(v3_normalize(dir), head_len))
			radius := head_len * 0.35
			rl.DrawCylinderEx(base, head, radius, 0, 6, col)
		}
	}

	rl.EndMode3D()
	rl.EndTextureMode()

	// Blit the (vertically flipped) render texture into the plot rect.
	src := rl.Rectangle{0, 0, f32(mv.rt.texture.width), -f32(mv.rt.texture.height)}
	rl.DrawTexturePro(mv.rt.texture, src, rect, rl.Vector2{0, 0}, 0, rl.WHITE)

	// Axis labels over the blitted scene.
	if bounds_ok {
		draw_3d_axis_labels(cam, axis_origin, axis_len, mv.rt.texture.width, mv.rt.texture.height, rect, sc)
	}

	// Overlay: title, control hint, and the arrow-size multiplier stepper.
	title_c := strings.clone_to_cstring(title, context.temp_allocator)
	draw_text(title_c, i32(rect.x + 8 * sc), i32(rect.y + 4 * sc), i32(11 * sc), theme.muted)
	hint := strings.clone_to_cstring("WASD move · right-drag look · wheel speed", context.temp_allocator)
	draw_text(hint, c.int(rect.x + 8 * sc), c.int(rect.y + 22 * sc), i32(11 * sc), theme.muted)
	if !app.exporting {
		quiver_scale_stepper(rect, scale, theme, sc)
	}
}