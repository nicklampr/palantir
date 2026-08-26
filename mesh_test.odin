package palantir

import "core:os"
import "core:testing"

@(test)
test_load_mesh :: proc(t: ^testing.T) {
	path := "/home/nick/prop3D/ellipsoid.json"
	if !os.exists(path) {
		return // prop3D output not present; skip silently
	}
	m, ok := load_mesh_dataset(path, "ellipsoid")
	testing.expect(t, ok, "failed to load mesh")
	if !ok {
		return
	}
	defer {
		mesh_destroy(m)
		free(m)
	}

	// Body + wake combined: numbers change with the prop3D example, so only
	// assert the structural invariants.
	testing.expect(t, m.n_vertices > 0, "expected some vertices")
	testing.expect(t, len(m.triangles) > 0, "expected some triangles")
	testing.expect(t, len(m.fields) >= 3, "expected at least x/y/z fields")
	names := [?]string{"x", "y", "z", "phi"}
	for name in names {
		testing.expectf(t, mesh_field(m, name) != nil, "%s field missing", name)
	}

	_, _, bounds_ok := mesh_bounds(m, 0, 1, 2)
	testing.expect(t, bounds_ok, "bounds failed")
}
