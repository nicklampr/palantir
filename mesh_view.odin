package palantir

// 3D mesh viewer: a fly camera (WASD + right-drag look) rendering a triangle
// mesh inside a plot rect, with optional per-vertex scalar coloring.
//
// Geometry is uploaded once to the GPU (rl.Model) and redrawn every frame in a
// single draw call; the cache is rebuilt only when the mesh or the selected
// fields change, so large meshes no longer stutter.

import "core:c"
import "core:math"
import "core:strings"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

// Unlit shader so the per-vertex scalar colors render at full brightness
// (no lighting dimming, no light setup required). Attribute/uniform names match
// raylib's defaults so DrawModel binds them automatically.
MESH_UNLIT_VS :: `
#version 330 core
in vec3 vertexPosition;
in vec4 vertexColor;
uniform mat4 mvp;
out vec4 fragColor;
void main() {
    fragColor = vertexColor;
    gl_Position = mvp * vec4(vertexPosition, 1.0);
}
`

MESH_UNLIT_FS :: `
#version 330 core
in vec4 fragColor;
out vec4 finalColor;
void main() {
    finalColor = fragColor;
}
`

Mesh_View :: struct {
	pos:       rl.Vector3,
	yaw:       f32,
	pitch:     f32,
	speed:     f32,
	fit:       bool, // refit to the current mesh bounds on the next frame
	wireframe: bool,
	// Offscreen target the 3D scene is rendered into (avoids scissor/viewport
	// pitfalls of 3D inside a sub-rectangle).
	rt:        rl.RenderTexture2D,
	rt_w:      i32,
	rt_h:      i32,
}

// GPU-batched render cache for the current mesh.
Mesh_Render_Cache :: struct {
	valid:    bool,
	mesh:     rl.Mesh,     // uploaded to the GPU (vaoId/vboId set)
	material: rl.Material, // material (unlit shader attached by the caller)
	// Owned CPU buffers (kept so we can free them ourselves).
	vertices: []f32,
	normals:  []f32,
	colors:   []u8,
	indices:  []u16,
	// Staleness key.
	src:      ^Mesh_Dataset,
	xi, yi, zi, ci: int,
}

mesh_view_init :: proc() -> Mesh_View {
	return Mesh_View {
		pos       = {0, 0, -12},
		yaw       = 0,
		pitch     = 0,
		speed     = 5,
		fit       = true,
		wireframe = false,
	}
}

mesh_view_unload :: proc(mv: ^Mesh_View) {
	if mv.rt.id != 0 {
		rl.UnloadRenderTexture(mv.rt)
		mv.rt = {}
		mv.rt_w = 0
		mv.rt_h = 0
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

// Fits the camera to the mesh bounding box: zero height (y = 0), looking
// horizontally into the mesh from outside its bounding box.
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
	mv.yaw = 0
	mv.pitch = 0
	dist := diag * 1.5
	mv.pos = rl.Vector3{center.x, 0, center.z - dist}
	mv.speed = diag * 0.5
}

// Frees the GPU model and the CPU buffers it references.
mesh_render_unload :: proc(cache: ^Mesh_Render_Cache) {
	if !cache.valid {
		return
	}
	// Null the CPU pointers so UnloadMesh's free is a no-op; we own them.
	cache.mesh.vertices = nil
	cache.mesh.texcoords = nil
	cache.mesh.normals = nil
	cache.mesh.colors = nil
	cache.mesh.indices = nil
	rl.UnloadMesh(cache.mesh)
	rl.UnloadMaterial(cache.material)
	delete(cache.vertices)
	delete(cache.normals)
	delete(cache.colors)
	delete(cache.indices)
	cache^ = {}
}

// Builds the batched GPU mesh for the current field selection.
mesh_render_build :: proc(m: ^Mesh_Dataset, xi, yi, zi, ci: int, theme: Theme, shader: rl.Shader) -> Mesh_Render_Cache {
	cache := Mesh_Render_Cache{}
	n := m.n_vertices
	ntri := len(m.triangles)
	if n == 0 || xi < 0 || yi < 0 || zi < 0 || xi >= len(m.fields) || yi >= len(m.fields) || zi >= len(m.fields) {
		return cache
	}

	xv := m.fields[xi].values
	yv := m.fields[yi].values
	zv := m.fields[zi].values

	has_color := ci >= 0 && ci < len(m.fields)
	cv := m.fields[ci].values if has_color else nil
	lo, hi := f64(0), f64(1)
	if has_color {
		lo, hi, _ = mesh_field_range(m, ci)
		if lo == hi {
			hi = lo + 1
		}
	}

	nxi := mesh_field_index(m, "nx")
	nyi := mesh_field_index(m, "ny")
	nzi := mesh_field_index(m, "nz")
	has_normals := nxi >= 0 && nyi >= 0 && nzi >= 0
	nxv := m.fields[nxi].values if has_normals else nil
	nyv := m.fields[nyi].values if has_normals else nil
	nzv := m.fields[nzi].values if has_normals else nil

	vertices := make([]f32, n * 3)
	normals := make([]f32, n * 3)
	colors := make([]u8, n * 4)
	for i in 0 ..< n {
		vertices[i * 3 + 0] = f32(xv[i])
		vertices[i * 3 + 1] = f32(yv[i])
		vertices[i * 3 + 2] = f32(zv[i])
		if has_normals {
			normals[i * 3 + 0] = f32(nxv[i])
			normals[i * 3 + 1] = f32(nyv[i])
			normals[i * 3 + 2] = f32(nzv[i])
		}
		col := theme.accent
		if has_color && cv != nil && !math.is_nan(cv[i]) {
			col = hue_lookup(lo, hi, cv[i], theme.axis_x, theme.axis_z)
		}
		colors[i * 4 + 0] = col.r
		colors[i * 4 + 1] = col.g
		colors[i * 4 + 2] = col.b
		colors[i * 4 + 3] = col.a
	}

	if ntri > 0 {
		indices := make([]u16, ntri * 3)
		ti := 0
		for t in m.triangles {
			if t[0] < n && t[1] < n && t[2] < n {
				indices[ti + 0] = u16(t[0])
				indices[ti + 1] = u16(t[1])
				indices[ti + 2] = u16(t[2])
				ti += 3
			}
		}
		if ti != ntri * 3 {
			indices = indices[:ti]
		}
		if ti > 0 {
			mesh := rl.Mesh {
				vertexCount   = c.int(n),
				triangleCount = c.int(ti / 3),
				vertices      = &vertices[0],
				normals       = &normals[0],
				colors        = &colors[0],
				indices       = &indices[0],
			}
			rl.UploadMesh(&mesh, false)
			mat := rl.LoadMaterialDefault()
			if shader.id != 0 {
				mat.shader = shader
			}
			cache.mesh = mesh
			cache.material = mat
			cache.indices = indices
		}
	}

	cache.vertices = vertices
	cache.normals = normals
	cache.colors = colors
	cache.valid = true
	return cache
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

	// Lazy-load the unlit shader so the scalar vertex colors show at full
	// brightness (it is attached to the mesh material during the rebuild).
	rs := &app.results
	if rs.mesh_shader.id == 0 {
		rs.mesh_shader = rl.LoadShaderFromMemory(MESH_UNLIT_VS, MESH_UNLIT_FS)
	}

	// Rebuild the GPU cache only when the mesh or field selection changes.
	cache := &app.results.mesh_render
	needs_rebuild := m != nil && (!cache.valid || cache.src != m || cache.xi != xi || cache.yi != yi || cache.zi != zi || cache.ci != ci)
	if needs_rebuild {
		if cache.valid {
			mesh_render_unload(cache)
		}
		cache^ = mesh_render_build(m, xi, yi, zi, ci, theme, rs.mesh_shader)
		cache.src = m
		cache.xi = xi
		cache.yi = yi
		cache.zi = zi
		cache.ci = ci
	}

	cam := rl.Camera3D {
		position   = mv.pos,
		target     = v3_add(mv.pos, cam_forward(mv.yaw, mv.pitch)),
		up         = {0, 1, 0},
		fovy       = 45,
		projection = .PERSPECTIVE,
	}

	// Render the 3D scene into an offscreen target sized to the plot rect, then
	// blit it. This keeps the 3D viewport consistent (raylib derives the camera
	// aspect from the current framebuffer, which is the render texture here).
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

	rl.DrawGrid(20, 1.0)

	// Thin sheets (e.g. the wake) must be visible from both sides, so draw the
	// mesh with backface culling disabled.
	rlgl.DisableBackfaceCulling()
	if cache.valid {
		if mv.wireframe {
			rlgl.EnableWireMode()
			rl.DrawMesh(cache.mesh, cache.material, rl.Matrix(1))
			rlgl.DisableWireMode()
		} else {
			rl.DrawMesh(cache.mesh, cache.material, rl.Matrix(1))
		}
	} else if m != nil && len(m.fields) > 0 && xi >= 0 && yi >= 0 && zi >= 0 {
		// Point-cloud fallback (no triangles).
		xv := m.fields[xi].values
		yv := m.fields[yi].values
		zv := m.fields[zi].values
		for i in 0 ..< m.n_vertices {
			rl.DrawSphere(rl.Vector3{f32(xv[i]), f32(yv[i]), f32(zv[i])}, 0.05, theme.axis_y)
		}
	}
	rlgl.EnableBackfaceCulling()

	rl.EndMode3D()
	rl.EndTextureMode()

	// Blit the (vertically flipped) render texture into the plot rect.
	src := rl.Rectangle{0, 0, f32(mv.rt.texture.width), -f32(mv.rt.texture.height)}
	rl.DrawTexturePro(mv.rt.texture, src, rect, rl.Vector2{0, 0}, 0, rl.WHITE)

	// Overlay: wireframe toggle + hint.
	toggle_w := 76 * sc
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
