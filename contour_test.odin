package palantir

import "core:math"
import "core:testing"

@(test)
test_scalar_grid_from_compact_axes :: proc(t: ^testing.T) {
	grid := scalar_grid_from_arrays(
		[]f64{0, 1, 2},
		[]f64{10, 20},
		[]f64{0, 1, 1, 2, 2, 3},
	)
	testing.expect(t, len(grid.x) == 3 && len(grid.y) == 2, "compact axis dimensions retained")
	testing.expect(t, len(grid.z) == 6, "flattened Z has nx*ny samples")
	testing.expect(t, grid.z[1] == 1 && grid.z[2] == 1 && grid.z[5] == 3, "Z uses x-slowest/y-fastest order")
}

@(test)
test_scalar_grid_from_row_samples :: proc(t: ^testing.T) {
	// Deliberately shuffled complete grid. Axis ordering is sorted, and
	// values are placed by coordinate pair rather than row.
	grid := scalar_grid_from_arrays(
		[]f64{1, 0, 1, 0},
		[]f64{10, 20, 20, 10},
		[]f64{110, 20, 120, 10},
	)
	testing.expect(t, len(grid.x) == 2 && len(grid.y) == 2, "row-wise regular grid reconstructed")
	testing.expect(t, grid.x[0] == 0 && grid.x[1] == 1, "row-wise coordinate axes are sorted")
	testing.expect(t, grid.z[0] == 10 && grid.z[1] == 20, "first X row mapped by coordinate")
	testing.expect(t, grid.z[2] == 110 && grid.z[3] == 120, "second X row reconstructed")
}

@(test)
test_scalar_grid_rejects_incomplete_grid :: proc(t: ^testing.T) {
	grid := scalar_grid_from_arrays([]f64{0, 0, 1}, []f64{0, 1, 0}, []f64{1, 2, 3})
	testing.expect(t, len(grid.x) == 0, "incomplete X/Y sample lattice is rejected")
}

@(test)
test_contour2d_linear_field :: proc(t: ^testing.T) {
	grid := scalar_grid_from_arrays([]f64{0, 1}, []f64{0, 1}, []f64{0, 1, 1, 2})
	segments := contour2d_segments(grid, 2)
	testing.expect(t, len(segments) == 2, "linear 2x2 field has one segment at each level")
	if len(segments) != 2 {return}

	// z=x+y. The first level is 2/3, intersecting the left and bottom edges.
	testing.expect(t, abs_f64(segments[0].level - 2.0 / 3.0) < 1e-9, "first level is evenly spaced")
	testing.expect(t, abs_f64(segments[0].a[0] + segments[0].a[1] - segments[0].level) < 1e-9, "first segment endpoint lies on the contour")
	testing.expect(t, abs_f64(segments[0].b[0] + segments[0].b[1] - segments[0].level) < 1e-9, "second endpoint lies on the contour")
	testing.expect(t, abs_f64(segments[1].level - 4.0 / 3.0) < 1e-9, "second level is evenly spaced")
}

@(test)
test_contour_skips_nan_cells :: proc(t: ^testing.T) {
	grid := scalar_grid_from_arrays(
		[]f64{0, 1, 2},
		[]f64{0, 1},
		[]f64{0, 1, f64_nan(), 2, 2, 3},
	)
	segments := contour2d_segments(grid, 3)
	for s in segments {
		testing.expect(t, !math.is_nan(s.a[0]) && !math.is_nan(s.b[0]), "NaN cell cannot create contour geometry")
	}
}
