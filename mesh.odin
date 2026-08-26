package palantir

// Triangle mesh model + loader, distinct from the columnar Dataset.
//
// A mesh JSON file is a top-level object whose numeric-array members become
// per-vertex "fields" (x, y, z, nx, phi, vmag, ...) and whose connectivity
// member (triangles / faces / indices) becomes an index list. The mesh viewer
// then maps any three fields to X/Y/Z and an optional field to color.

import "core:encoding/json"
import "core:math"
import "core:os"
import "core:sort"
import "core:strings"

Mesh_Field :: struct {
	name:   string,
	values: []f64,
}

Mesh_Dataset :: struct {
	name:       string,
	path:       string,
	n_vertices: int,
	fields:     []Mesh_Field,
	triangles:  [][3]int,
}

mesh_destroy :: proc(m: ^Mesh_Dataset) {
	for &f in m.fields {
		delete(f.name)
		delete(f.values)
	}
	delete(m.fields)
	delete(m.triangles)
	delete(m.name)
	delete(m.path)
	m^ = {}
}

mesh_field :: proc(m: ^Mesh_Dataset, name: string) -> ^Mesh_Field {
	for &f in m.fields {
		if equal_ci(f.name, name) {
			return &f
		}
	}
	return nil
}

mesh_field_names :: proc(m: ^Mesh_Dataset) -> []string {
	if m == nil {
		return nil
	}
	names := make([]string, len(m.fields), context.temp_allocator)
	for f, i in m.fields {
		names[i] = f.name
	}
	return names
}

mesh_field_index :: proc(m: ^Mesh_Dataset, name: string) -> int {
	for f, i in m.fields {
		if equal_ci(f.name, name) {
			return i
		}
	}
	return -1
}

// Names that identify the connectivity array.
is_triangle_key :: proc(name: string) -> bool {
	lower := strings.to_lower(name, context.temp_allocator)
	switch lower {
	case "triangles", "triangle", "faces", "face", "indices", "index", "tris", "tri":
		return true
	case:
		return false
	}
}

json_num :: proc(v: json.Value) -> (f64, bool) {
	#partial switch c in v {
	case json.Integer:
		return f64(c), true
	case json.Float:
		return c, true
	case:
		return 0, false
	}
	unreachable()
}

// Loads a triangle mesh from a JSON object: numeric-array members become
// vertex fields, a connectivity array member becomes triangles.
load_mesh_dataset :: proc(path, display_name: string) -> (^Mesh_Dataset, bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return nil, false
	}
	defer delete(data)

	val, perr := json.parse(data)
	if perr != nil {
		return nil, false
	}
	defer json.destroy_value(val)

	obj, is_obj := val.(json.Object)
	if !is_obj {
		return nil, false
	}

	m := new(Mesh_Dataset)
	m.name = strings.clone(display_name)
	m.path = strings.clone(path)

	// First pass: collect numeric-array members and the connectivity member.
	names := make([dynamic]string, context.temp_allocator)
	for k, v in obj {
		if is_triangle_key(k) {
			continue
		}
		arr, is_arr := v.(json.Array)
		if !is_arr || len(arr) == 0 {
			continue
		}
		// Must be an array of scalars (numbers).
		if _, ok := json_num(arr[0]); !ok {
			continue
		}
		append(&names, k)
	}
	sort.quick_sort_proc(names[:], proc(a, b: string) -> int {return strings.compare(a, b)})

	n_vertices := 0
	if len(names) > 0 {
		n_vertices = len(obj[names[0]].(json.Array))
	}
	m.n_vertices = n_vertices
	m.fields = make([]Mesh_Field, len(names))
	for k, i in names {
		arr := obj[k].(json.Array)
		vals := make([]f64, n_vertices)
		for r in 0 ..< n_vertices {
			if r < len(arr) {
				if f, ok := json_num(arr[r]); ok {
					vals[r] = f
				} else {
					vals[r] = f64_nan()
				}
			} else {
				vals[r] = f64_nan()
			}
		}
		m.fields[i] = Mesh_Field{name = strings.clone(k), values = vals}
	}

	// Connectivity: first key that parses as an array of int triplets.
	for k, v in obj {
		if !is_triangle_key(k) {
			continue
		}
		arr, is_arr := v.(json.Array)
		if !is_arr {
			continue
		}
		tris := make([dynamic][3]int, 0, len(arr), context.allocator)
		good := len(arr) > 0
		for e in arr {
			sub, is_sub := e.(json.Array)
			if !is_sub || len(sub) < 3 {
				good = false
				break
			}
			a, aok := json_num(sub[0])
			b, bok := json_num(sub[1])
			c, cok := json_num(sub[2])
			if !aok || !bok || !cok {
				good = false
				break
			}
			append(&tris, [3]int{int(a), int(b), int(c)})
		}
		if good {
			m.triangles = tris[:]
		} else {
			delete(tris)
		}
		break
	}

	if n_vertices == 0 {
		mesh_destroy(m)
		free(m)
		return nil, false
	}
	return m, true
}

// Min/max of a mesh field (ignoring NaNs). ok=false when the field is empty.
mesh_field_range :: proc(m: ^Mesh_Dataset, field_idx: int) -> (lo, hi: f64, ok: bool) {
	if m == nil || field_idx < 0 || field_idx >= len(m.fields) {
		return 0, 0, false
	}
	lo = math.inf_f64(1)
	hi = math.inf_f64(-1)
	for v in m.fields[field_idx].values {
		if math.is_nan(v) {
			continue
		}
		lo = min(lo, v)
		hi = max(hi, v)
		ok = true
	}
	return
}

// Bounding box of the mesh vertices given X/Y/Z field indices.
mesh_bounds :: proc(m: ^Mesh_Dataset, xi, yi, zi: int) -> (minp, maxp: [3]f64, ok: bool) {
	if m == nil {
		return {}, {}, false
	}
	xv := m.fields[xi].values if xi >= 0 && xi < len(m.fields) else nil
	yv := m.fields[yi].values if yi >= 0 && yi < len(m.fields) else nil
	zv := m.fields[zi].values if zi >= 0 && zi < len(m.fields) else nil
	if xv == nil || yv == nil || zv == nil {
		return {}, {}, false
	}
	minp = {math.inf_f64(1), math.inf_f64(1), math.inf_f64(1)}
	maxp = {math.inf_f64(-1), math.inf_f64(-1), math.inf_f64(-1)}
	n := min(len(xv), len(yv), len(zv), m.n_vertices)
	for i in 0 ..< n {
		minp[0] = min(minp[0], xv[i])
		minp[1] = min(minp[1], yv[i])
		minp[2] = min(minp[2], zv[i])
		maxp[0] = max(maxp[0], xv[i])
		maxp[1] = max(maxp[1], yv[i])
		maxp[2] = max(maxp[2], zv[i])
	}
	return minp, maxp, true
}
