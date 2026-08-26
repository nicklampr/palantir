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

	testing.expect(t, m.n_vertices == 512, "expected 512 vertices")
	testing.expect(t, len(m.triangles) == 960, "expected 960 triangles")
	names := [?]string{"x", "y", "z", "vmag", "phi", "sigma"}
	for name in names {
		testing.expectf(t, mesh_field(m, name) != nil, "%s field missing", name)
	}

	_, _, bounds_ok := mesh_bounds(m, 0, 1, 2)
	testing.expect(t, bounds_ok, "bounds failed")
}
