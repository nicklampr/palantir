package palantir

// Regular scalar fields are stored as three columns in the results table. This
// adapter accepts both compact axes + a flattened field (x-slowest, y-fastest,
// matching quiver) and row-wise X/Y/Z samples on a complete rectangular grid.

import "core:math"
import "core:sort"

Scalar_Grid_2D :: struct {
	x: []f64,
	y: []f64,
	z: []f64, // z[ix*ny + iy]
}

SCALAR_GRID_MAX_POINTS :: 1_000_000

scalar_grid_from_arrays :: proc(X, Y, Z: []f64) -> Scalar_Grid_2D {
	nx := valid_prefix_len(X)
	ny := valid_prefix_len(Y)
	if nx > 0 && ny > 0 &&
	   nx <= SCALAR_GRID_MAX_POINTS / ny &&
	   nx * ny == len(Z) &&
	   len(Z) <= SCALAR_GRID_MAX_POINTS {
		return Scalar_Grid_2D {
			x = X[:nx],
			y = Y[:ny],
			z = Z,
		}
	}

	// Fallback for regular-grid samples represented as one X/Y/Z row per
	// point. Preserve the first-seen axis order, then place every point into
	// the x-major/y-minor matrix. Incomplete or duplicate grids are rejected.
	n := min(len(X), len(Y), len(Z))
	if n < 4 || n > SCALAR_GRID_MAX_POINTS {
		return {}
	}

	xs := make([dynamic]f64, 0, min(n, 1024), context.temp_allocator)
	ys := make([dynamic]f64, 0, min(n, 1024), context.temp_allocator)
	x_index := make(map[f64]int, context.temp_allocator)
	y_index := make(map[f64]int, context.temp_allocator)
	for i in 0 ..< n {
		x, y := X[i], Y[i]
		if math.is_nan(x) || math.is_nan(y) {
			continue
		}
		if _, exists := x_index[x]; !exists {
			x_index[x] = len(xs)
			append(&xs, x)
		}
		if _, exists := y_index[y]; !exists {
			y_index[y] = len(ys)
			append(&ys, y)
		}
		if len(xs) * len(ys) > n {
			return {}
		}
	}

	sort.quick_sort_proc(xs[:], proc(a, b: f64) -> int {
		if a < b {return -1}
		if a > b {return 1}
		return 0
	})
	sort.quick_sort_proc(ys[:], proc(a, b: f64) -> int {
		if a < b {return -1}
		if a > b {return 1}
		return 0
	})
	clear(&x_index)
	clear(&y_index)
	for x, i in xs {x_index[x] = i}
	for y, i in ys {y_index[y] = i}

	nx, ny = len(xs), len(ys)
	if nx < 2 || ny < 2 || nx * ny != n {
		return {}
	}

	values := make([]f64, nx * ny, context.temp_allocator)
	seen := make([]bool, nx * ny, context.temp_allocator)
	for i in 0 ..< len(values) {
		values[i] = f64_nan()
	}
	for i in 0 ..< n {
		x, y := X[i], Y[i]
		if math.is_nan(x) || math.is_nan(y) {
			return {}
		}
		ix, x_ok := x_index[x]
		iy, y_ok := y_index[y]
		if !x_ok || !y_ok {
			return {}
		}
		k := ix * ny + iy
		if seen[k] {
			return {}
		}
		seen[k] = true
		values[k] = Z[i]
	}
	for present in seen {
		if !present {
			return {}
		}
	}
	return Scalar_Grid_2D{x = xs[:], y = ys[:], z = values}
}

scalar_grid_range :: proc(grid: Scalar_Grid_2D) -> (z_min, z_max: f64, ok: bool) {
	z_min = math.inf_f64(1)
	z_max = math.inf_f64(-1)
	for z in grid.z {
		if math.is_nan(z) {
			continue
		}
		z_min = min(z_min, z)
		z_max = max(z_max, z)
		ok = true
	}
	return
}

scalar_grid_bounds_3d :: proc(grid: Scalar_Grid_2D) -> (minp, maxp: [3]f64, ok: bool) {
	if len(grid.x) == 0 || len(grid.y) == 0 {
		return {}, {}, false
	}
	minp = {math.inf_f64(1), math.inf_f64(1), math.inf_f64(1)}
	maxp = {math.inf_f64(-1), math.inf_f64(-1), math.inf_f64(-1)}
	for x in grid.x {
		if math.is_nan(x) {continue}
		minp[0] = min(minp[0], x)
		maxp[0] = max(maxp[0], x)
	}
	for y in grid.y {
		if math.is_nan(y) {continue}
		minp[1] = min(minp[1], y)
		maxp[1] = max(maxp[1], y)
	}
	for z in grid.z {
		if math.is_nan(z) {continue}
		minp[2] = min(minp[2], z)
		maxp[2] = max(maxp[2], z)
		ok = true
	}
	return minp, maxp, ok
}
