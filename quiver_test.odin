package palantir

// Headless tests for the quiver plot helpers (no raylib window needed): the
// meshgrid-free index pairing, bounds/scale math, arrowhead geometry, and the
// magnitude color domain.

import "core:math"
import "core:os"
import "core:testing"

@(test)
test_quiver2d_min_length_pairs :: proc(t: ^testing.T) {
	// Arrays of different lengths: the arrow count is the shortest, and each
	// arrow pairs values by index (scattered fallback — no grid assumed).
	X := []f64{1, 2, 3, 4, 5}
	Y := []f64{10, 20, 30}
	U := []f64{0.5, 1.0, 2.0, 8.0}
	V := []f64{-1, -2, -3, -4, -5, -6}

	arrows := quiver2d_from_arrays(X, Y, U, V)
	testing.expect(t, len(arrows) == 3, "arrow count = min length across arrays")

	testing.expect(t, arrows[0] == Quiver2D{1, 10, 0.5, -1}, "arrow 0 paired by index")
	testing.expect(t, arrows[1] == Quiver2D{2, 20, 1.0, -2}, "arrow 1 paired by index")
	testing.expect(t, arrows[2] == Quiver2D{3, 30, 2.0, -3}, "arrow 2 paired by index")
}

@(test)
test_quiver3d_min_length_pairs :: proc(t: ^testing.T) {
	X := []f64{0, 1, 2}
	Y := []f64{5, 6, 7, 8}
	Z := []f64{-1, -2, -3, -4, -5}
	U := []f64{0.1, 0.2}
	V := []f64{1, 1, 1}
	W := []f64{0, 0, 0, 0}

	arrows := quiver3d_from_arrays(X, Y, Z, U, V, W)
	testing.expect(t, len(arrows) == 2, "arrow count = min length across six arrays")
	testing.expect(t, arrows[1] == Quiver3D{1, 6, -2, 0.2, 1, 0}, "arrow 1 paired by index")
}

@(test)
test_valid_prefix_len :: proc(t: ^testing.T) {
	testing.expect(t, valid_prefix_len([]f64{1, 2, 3}) == 3, "all valid")
	testing.expect(t, valid_prefix_len([]f64{f64_nan(), f64_nan()}) == 0, "all NaN")
	// Clean prefix followed by NaN padding (how the app's JSON loader pads
	// shorter columns to the dataset row count).
	testing.expect(t, valid_prefix_len([]f64{0, 1, 2, f64_nan(), f64_nan()}) == 3, "NaN-suffixed prefix")
	// A NaN hole before a valid value is not a clean prefix.
	testing.expect(t, valid_prefix_len([]f64{0, f64_nan(), 2}) == 0, "NaN hole rejected")
}

@(test)
test_quiver_grid_reconstruction_2d :: proc(t: ^testing.T) {
	// Compact axes X/Y (len 2 each) with U/V as the flattened 2x2 product
	// (x-slowest order): the grid must expand to 4 arrows.
	X := []f64{0, 1}
	Y := []f64{10, 20}
	U := []f64{1, 2, 3, 4}
	V := []f64{5, 6, 7, 8}

	arrows := quiver2d_from_arrays(X, Y, U, V)
	testing.expect(t, len(arrows) == 4, "2D grid expands to nx*ny arrows")
	testing.expect(t, arrows[0] == Quiver2D{0, 10, 1, 5}, "grid arrow (0,0)")
	testing.expect(t, arrows[1] == Quiver2D{0, 20, 2, 6}, "grid arrow (0,1): y fastest")
	testing.expect(t, arrows[2] == Quiver2D{1, 10, 3, 7}, "grid arrow (1,0)")
	testing.expect(t, arrows[3] == Quiver2D{1, 20, 4, 8}, "grid arrow (1,1)")
}

@(test)
test_quiver_grid_reconstruction_3d :: proc(t: ^testing.T) {
	// The prop3D layout: compact axes x/y/z (len 2 each) + flattened 2x2x2
	// field, NaN-padded to a longer dataset row count. Must expand to 8 arrows.
	X := []f64{0, 1, f64_nan(), f64_nan()}
	Y := []f64{10, 20, f64_nan(), f64_nan()}
	Z := []f64{100, 200, f64_nan(), f64_nan()}
	U := []f64{1, 2, 3, 4, 5, 6, 7, 8}
	V := []f64{1, 1, 1, 1, 1, 1, 1, 1}
	W := []f64{0, 0, 0, 0, 0, 0, 0, 0}

	arrows := quiver3d_from_arrays(X, Y, Z, U, V, W)
	testing.expect(t, len(arrows) == 8, "3D grid expands to nx*ny*nz arrows")
	// x-slowest / z-fastest flattening: index k = (ix*ny + iy)*nz + iz.
	testing.expect(t, arrows[0] == Quiver3D{0, 10, 100, 1, 1, 0}, "grid arrow (0,0,0)")
	testing.expect(t, arrows[1] == Quiver3D{0, 10, 200, 2, 1, 0}, "z fastest")
	testing.expect(t, arrows[2] == Quiver3D{0, 20, 100, 3, 1, 0}, "then y")
	testing.expect(t, arrows[4] == Quiver3D{1, 10, 100, 5, 1, 0}, "then x")
}

@(test)
test_quiver_scale_applied :: proc(t: ^testing.T) {
	// The scale multiplier scales the drawn head by the same factor, so the
	// fitted bounds must cover the scaled heads.
	arrows := []Quiver3D {
		{x = 0, y = 0, z = 0, u = 1, v = 0, w = 0},
	}
	_, maxp, ok := quiver3d_fit_bounds(arrows, 2)
	testing.expect(t, ok, "fit bounds ok")
	testing.expect(t, maxp[0] == 2, "scaled head at x=2 for scale=2")

	_, maxp1, _ := quiver3d_fit_bounds(arrows, 0.5)
	testing.expect(t, maxp1[0] == 0.5, "scaled head shrinks below 1")
}

@(test)
test_quiver_prop3d_grid :: proc(t: ^testing.T) {
	// End-to-end check against prop3D's actual output: compact axes x/y/z
	// (nx each) with u/v/w flattened to nx*ny*nz. The dataset loader
	// NaN-pads the axes to the field row count; the grid reconstruction must
	// restore the full field. Assertions are structural so the test survives
	// the file being regenerated with a different domain.
	path := "/home/nick/prop3D/quiver.json"
	if !os.exists(path) {
		return // prop3D output not present; skip silently
	}
	ds, ok := load_json_dataset(path, "quiver")
	testing.expect(t, ok, "failed to load prop3D quiver.json")
	if !ok {
		return
	}
	defer {
		dataset_destroy(ds)
		free(ds)
	}

	xs := ds_quiver_vals(ds, ds_column(ds, "x"), 100000)
	ys := ds_quiver_vals(ds, ds_column(ds, "y"), 100000)
	zs := ds_quiver_vals(ds, ds_column(ds, "z"), 100000)
	us := ds_quiver_vals(ds, ds_column(ds, "u"), 100000)
	vs := ds_quiver_vals(ds, ds_column(ds, "v"), 100000)
	ws := ds_quiver_vals(ds, ds_column(ds, "w"), 100000)

	nx, ny, nz := valid_prefix_len(xs), valid_prefix_len(ys), valid_prefix_len(zs)
	field := nx * ny * nz
	testing.expect(t, field > 1 && len(us) == field, "axes multiply to the field length")
	if len(us) != field || field <= 1 {
		return
	}

	arrows := quiver3d_from_arrays(xs, ys, zs, us, vs, ws)
	testing.expect(t, len(arrows) == field, "full field reconstructed, not the axis length")
	if len(arrows) == 0 {
		return
	}

	// x-slowest / z-fastest flattening: index k = (ix*ny + iy)*nz + iz must map
	// to the axes and match the field values at k.
	check := []int{0, 1, nz, ny * nz, field - 1, 17}
	for k in check {
		if k < 0 || k >= field {
			continue
		}
		ix := k / (ny * nz)
		iy := (k / nz) % ny
		iz := k % nz
		a := arrows[k]
		testing.expectf(t, a.x == xs[ix], "arrow %d x = axis[%d]", k, ix)
		testing.expectf(t, a.y == ys[iy], "arrow %d y = axis[%d]", k, iy)
		testing.expectf(t, a.z == zs[iz], "arrow %d z = axis[%d]", k, iz)
		testing.expectf(t, a.u == us[k] && a.v == vs[k] && a.w == ws[k], "arrow %d components = field[%d]", k, k)
	}
}

@(test)
test_quiver_bounds_cover_heads :: proc(t: ^testing.T) {
	arrows := []Quiver2D {
		{x = 0, y = 0, u = 3, v = 4},
		{x = 10, y = 10, u = -2, v = -1},
		{x = 5, y = 5, u = f64_nan(), v = 1}, // NaN entry skipped
	}
	minp, maxp, ok := quiver2d_bounds(arrows)
	testing.expect(t, ok, "bounds found despite NaN entry")
	testing.expect(t, minp == [2]f64{0, 0}, "min is the smallest tail/head")
	testing.expect(t, maxp == [2]f64{10, 10}, "max covers a head (10,-2) -> x=10, (3,4) -> y=4")

	// The NaN arrow contributes nothing: heads at (3,4) and (8,9).
	minp3, maxp3, ok3 := quiver3d_bounds([]Quiver3D{{x = 0, y = 0, z = 0, u = 1, v = 2, w = 3}})
	testing.expect(t, ok3, "3d bounds ok")
	testing.expect(t, minp3 == [3]f64{0, 0, 0} && maxp3 == [3]f64{1, 2, 3}, "3d bounds cover tail+head")
}

@(test)
test_quiver_autoscale :: proc(t: ^testing.T) {
	// Longest arrow (10 px) scaled to a 40 px target -> factor 4.
	testing.expect(t, abs_f64(quiver2d_autoscale([]f64{1, 10, 5}, 40) - 4) < 1e-9, "scale up")
	// Longest arrow (100 px) scaled to a 40 px target -> factor 0.4.
	testing.expect(t, abs_f64(quiver2d_autoscale([]f64{100, 20}, 40) - 0.4) < 1e-9, "scale down")
	// Empty / zero input stays neutral.
	testing.expect(t, quiver2d_autoscale(nil, 40) == 1, "empty stays 1")
	testing.expect(t, quiver2d_autoscale([]f64{0, 0}, 40) == 1, "zero stays 1")
	// NaN lengths are ignored.
	testing.expect(t, abs_f64(quiver2d_autoscale([]f64{f64_nan(), 8}, 40) - 5) < 1e-9, "NaN ignored")
}

@(test)
test_quiver_head_barbs :: proc(t: ^testing.T) {
	// Arrow pointing right (+x); head at origin. Barbs must point back toward
	// the tail (-x) and be symmetric about the shaft.
	head := [2]f64{0, 0}
	dir := [2]f64{1, 0}
	head_px := 10.0
	angle := 25.0 * math.PI / 180.0
	b1, b2 := quiver2d_head_barbs(head, dir, head_px, angle)

	// Both barbs end behind the head (negative x).
	testing.expect(t, b1[0] < 0 && b2[0] < 0, "barbs point back toward the tail")
	// Symmetric about the shaft: y components are opposites.
	testing.expect(t, abs_f64(b1[1] + b2[1]) < 1e-9, "barbs symmetric about the shaft")
	// Barb length equals head_px.
	len1 := math.sqrt(b1[0] * b1[0] + b1[1] * b1[1])
	testing.expect(t, abs_f64(len1 - head_px) < 1e-9, "barb length equals head_px")
}

@(test)
test_quiver_magnitude_domain :: proc(t: ^testing.T) {
	lo, hi, ok := quiver2d_magnitude_range([]Quiver2D {
		{u = 3, v = 4}, // 5
		{u = 6, v = 8}, // 10
		{u = f64_nan(), v = 1},
	})
	testing.expect(t, ok, "magnitude domain found")
	testing.expect(t, abs_f64(lo - 5) < 1e-9 && abs_f64(hi - 10) < 1e-9, "magnitude domain bounds")

	// Degenerate domain (all identical magnitude) is expanded so hue_lookup
	// never divides by zero.
	lo2, hi2, ok2 := quiver2d_magnitude_range([]Quiver2D{{u = 0, v = 2}, {u = 2, v = 0}})
	testing.expect(t, ok2 && lo2 == 2 && hi2 == 3, "degenerate domain expanded")
}