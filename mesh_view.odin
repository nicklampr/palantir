package palantir

// 3D mesh viewer: a fly camera (WASD + right-drag look) rendering a triangle
// mesh inside a plot rect, with optional per-vertex scalar coloring.

import "core:c"
import "core:math"
import "core:strings"
import rl "vendor:raylib"

Mesh_View :: struct {
	pos:       rl.Vector3,
	yaw:       f32,
	pitch:     f32,
	speed:     f32,
	fit:       bool, // refit to the current mesh bounds on the next frame
	wireframe: bool,
}

mesh_view_init :: proc() -> Mesh_View {
	return Mesh_View {
		pos       = {12, 8, 12},
		yaw       = 0.8,
		pitch     = 0.35,
		speed     = 5,
		fit       = true,
		wireframe = false,
	}
}

v3_add :: proc(a, b: rl.Vector3) -> rl.Vector3 {return {a.x + b.x, a.y + b.y, a.z + b.z}}
v3_sub :: proc(a, b: rl.Vector3) -> rl.Vector3 {return {a.x - b.x, a.y - b.y, a.z - b.z}}
v3_scale :: proc(a: rl.Vector3, s: f32) -> rl.Vector3 {return {a.x * s, a.y * s, a.z * s}}
v3_len :: proc(a: rl.Vector3) -> f32 {return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)}
v3_normalize :: proc(a: rl.Vector3) -> rl.Vector3 {
	l := v3_len(a)
	if l == 0 {return {}}
	return v3_scale(a, 1.0 / l)
}
v3_cross :: proc(a, b: rl.Vector3) -> rl.Vector3 {
	return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}
}

// Forward direction from yaw/pitch (Y-up).
cam_forward :: proc(yaw, pitch: f32) -> rl.Vector3 {
	cp := math.cos(pitch)
	return rl.Vector3{cp * math.sin(yaw), math.sin(pitch), cp * math.cos(yaw)}
}

cam_right :: proc(yaw, pitch: f32) -> rl.Vector3 {
	return v3_normalize(v3_cross(cam_forward(yaw, pitch), rl.Vector3{0, 1, 0}))
}

// Camera update: WASD move, right-drag look, wheel speed. `active` gates all
// input so the camera never fights the palette, dropdowns or text fields.
mesh_view_update :: proc(mv: ^Mesh_View, rect: rl.Rectangle, active: bool) {
	if !active {
		return
	}
	mouse := rl.GetMousePosition()
	if !rl.CheckCollisionPointRec(mouse, rect) {
		return
	}

	dt := rl.GetFrameTime()
	if dt <= 0 {
		dt = 1.0 / 60.0
	}

	if rl.IsMouseButtonDown(.RIGHT) {
		delta := rl.GetMouseDelta()
		mv.yaw -= delta.x * 0.003
		mv.pitch += delta.y * 0.003
		mv.pitch = clamp(mv.pitch, -1.55, 1.55)
	}

	forward := cam_forward(mv.yaw, mv.pitch)
	right := cam_right(mv.yaw, mv.pitch)
	up := rl.Vector3{0, 1, 0}

	vel := rl.Vector3{}
	if rl.IsKeyDown(.W) {vel = v3_add(vel, forward)}
	if rl.IsKeyDown(.S) {vel = v3_sub(vel, forward)}
	if rl.IsKeyDown(.D) {vel = v3_add(vel, right)}
	if rl.IsKeyDown(.A) {vel = v3_sub(vel, right)}
	if rl.IsKeyDown(.E) || rl.IsKeyDown(.SPACE) {vel = v3_add(vel, up)}
	if rl.IsKeyDown(.Q) || rl.IsKeyDown(.LEFT_SHIFT) {vel = v3_sub(vel, up)}
	if v3_len(vel) > 0 {
		mv.pos = v3_add(mv.pos, v3_scale(v3_normalize(vel), mv.speed * dt))
	}

	if wheel := rl.GetMouseWheelMove(); wheel != 0 {
		mv.speed = clamp(mv.speed * (1.0 + wheel * 0.12), 0.05, 500)
	}
}

// Fits the camera to the mesh bounding box.
mesh_view_fit :: proc(mv: ^Mesh_View, m: ^Mesh_Dataset, xi, yi, zi: int) {
	minp, maxp, ok := mesh_bounds(m, xi, yi, zi)
	if !ok {
		return
	}
	center := rl.Vector3 {
		f32((minp[0] + maxp[0]) * 0.5),
		f32((minp[1] + maxp[1]) * 0.5),
		f32((minp[2] + maxp[2]) * 0.5),
	}
	diag := v3_len(v3_sub(rl.Vector3{f32(maxp[0]), f32(maxp[1]), f32(maxp[2])}, rl.Vector3{f32(minp[0]), f32(minp[1]), f32(minp[2])}))
	if diag <= 0 {
		diag = 1
	}
	fwd := cam_forward(mv.yaw, mv.pitch)
	mv.pos = v3_add(center, v3_scale(fwd, diag * 1.4))
	mv.speed = diag * 0.5
}

// Color for a scalar value in [lo, hi] using the x->z theme ramp.
mesh_field_color :: proc(lo, hi, v: f64, theme: Theme) -> rl.Color {
	return hue_lookup(lo, hi, v, theme.axis_x, theme.axis_z)
}

draw_mesh_view :: proc(
	app: ^App,
	m: ^Mesh_Dataset,
	xi, yi, zi, ci: int,
	rect: rl.Rectangle,
	theme: Theme,
	sc: f32,
) {
	mv := &app.results.mesh_view

	if mv.fit && m != nil {
		mesh_view_fit(mv, m, xi, yi, zi)
		mv.fit = false
	}

	active := !app.palette.open && !results_any_dropdown_open(&app.results)
	mesh_view_update(mv, rect, active)

	cam := rl.Camera3D {
		position   = mv.pos,
		target     = v3_add(mv.pos, cam_forward(mv.yaw, mv.pitch)),
		up         = {0, 1, 0},
		fovy       = 45,
		projection = .PERSPECTIVE,
	}

	// Color range for the selected scalar field.
	color_lo, color_hi := f64(0), f64(1)
	has_color := ci >= 0 && ci < len(m.fields)

	rl.BeginScissorMode(c.int(rect.x), c.int(rect.y), c.int(rect.width), c.int(rect.height))
	rl.BeginMode3D(cam)

	if has_color {
		color_lo, color_hi, _ = mesh_field_range(m, ci)
		if color_lo == color_hi {
			color_hi = color_lo + 1
		}
	}

	// Ground grid for orientation.
	rl.DrawGrid(20, 1.0)

	if m != nil && len(m.triangles) > 0 {
		xv := m.fields[xi].values
		yv := m.fields[yi].values
		zv := m.fields[zi].values
		cv := m.fields[ci].values if has_color else nil

		// Filled triangles (flat-shaded by the mean of the vertex colors).
		for tri in m.triangles {
			if tri[0] >= m.n_vertices || tri[1] >= m.n_vertices || tri[2] >= m.n_vertices {
				continue
			}
			a := rl.Vector3{f32(xv[tri[0]]), f32(yv[tri[0]]), f32(zv[tri[0]])}
			b := rl.Vector3{f32(xv[tri[1]]), f32(yv[tri[1]]), f32(zv[tri[1]])}
			c := rl.Vector3{f32(xv[tri[2]]), f32(yv[tri[2]]), f32(zv[tri[2]])}
			col := theme.accent
			if has_color && cv != nil {
				va := cv[tri[0]]
				vb := cv[tri[1]]
				vc := cv[tri[2]]
				col = mesh_field_color(color_lo, color_hi, (va + vb + vc) / 3.0, theme)
			}
			rl.DrawTriangle3D(a, b, c, col)
		}

		// Wireframe edges.
		if mv.wireframe {
			edge := rl.Fade(theme.text, 0.6)
			for tri in m.triangles {
				if tri[0] >= m.n_vertices || tri[1] >= m.n_vertices || tri[2] >= m.n_vertices {
					continue
				}
				a := rl.Vector3{f32(xv[tri[0]]), f32(yv[tri[0]]), f32(zv[tri[0]])}
				b := rl.Vector3{f32(xv[tri[1]]), f32(yv[tri[1]]), f32(zv[tri[1]])}
				c := rl.Vector3{f32(xv[tri[2]]), f32(yv[tri[2]]), f32(zv[tri[2]])}
				rl.DrawLine3D(a, b, edge)
				rl.DrawLine3D(b, c, edge)
				rl.DrawLine3D(c, a, edge)
			}
		}
	}

	// Vertices as colored points (so point clouds work even without triangles).
	if m != nil && len(m.fields) > 0 {
		xv := m.fields[xi].values
		yv := m.fields[yi].values
		zv := m.fields[zi].values
		cv := m.fields[ci].values if has_color else nil
		pt_r := f32(0.02 * mv.speed)
		pt_r = clamp(pt_r, 0.01, 0.2)
		for i in 0 ..< m.n_vertices {
			p := rl.Vector3{f32(xv[i]), f32(yv[i]), f32(zv[i])}
			col := theme.axis_y
			if has_color && cv != nil {
				col = mesh_field_color(color_lo, color_hi, cv[i], theme)
			}
			rl.DrawSphere(p, pt_r, col)
		}
	}

	rl.EndMode3D()
	rl.EndScissorMode()

	// Overlay: toggle button + hint.
	toggle_w := 70 * sc
	toggle := rl.Rectangle{rect.x + rect.width - toggle_w - 8 * sc, rect.y + 6 * sc, toggle_w, 24 * sc}
	label: cstring = "Solid"
	if mv.wireframe {
		label = "Wireframe"
	}
	if draw_button(toggle, label, theme, sc) {
		mv.wireframe = !mv.wireframe
	}
	hint := strings.clone_to_cstring("WASD move · right-drag look · wheel speed", context.temp_allocator)
	draw_text(hint, c.int(rect.x + 8 * sc), c.int(rect.y + 8 * sc), i32(11 * sc), theme.muted)
}
