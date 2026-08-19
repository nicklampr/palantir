package palantir

// Generic columnar dataset model + loaders for .csv / .json result files.
//
// Both formats are materialized into the same shape: a set of named columns
// over a fixed number of rows. JSON files are auto-detected as either AoS
// (array of objects / rows) or SoA (object of equal-length arrays), with a
// fallback for a container object that holds a nested array of objects.
//
// Rendering is what is lazy here: loading happens once per file (cached in
// App), and the raw-data viewer only formats the rows that are actually
// visible, so scrolling a multi-million-row table never re-parses anything.

import "core:encoding/csv"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:sort"
import "core:strconv"
import "core:strings"
import "core:time"

// Cached, sampled map input for a dataset. The earth map only needs lat/lon
// per point; everything the hover tooltip shows is read back from the dataset's
// columns at the original row, so no row type is hardcoded.
Map_Cache :: struct {
	rows:   []int, // original row index per sampled point
	lat:    []f64, // sampled latitudes
	lon:    []f64, // sampled longitudes
	time:   []f64, // sampled unix seconds (NaN when the dataset has no time column)
	cols:   []int, // column indices shown in the hover tooltip (auto-detected)
	marker: int,   // lat_idx + len(columns) * lon_idx; invalidates on column change
	ok:     bool,
}

ColumnType :: enum {
	Float, // all cells parsed as numbers
	Bool,  // all cells were true/false/yes/no/on/off/0/1
	Str,   // at least one non-numeric cell
}

Column :: struct {
	name:   string,
	type:   ColumnType,
	// Always present. NaN marks a cell that was empty or non-numeric.
	floats: []f64,
	// Present only for Str columns (owned strings, parallel to `floats`).
	strs:   []string,
}

Dataset :: struct {
	name:    string,
	path:    string,
	n_rows:  int,
	columns: []Column,
	// Cached, sampled map input (see Map_Cache), built on demand.
	map_cache: Map_Cache,
}

f64_nan :: proc() -> f64 {
	// core:math has no nan(); inf - inf is NaN and compiles to nothing.
	return math.inf_f64(1) - math.inf_f64(1)
}

dataset_destroy :: proc(ds: ^Dataset) {
	for &col in ds.columns {
		delete(col.name)
		delete(col.floats)
		if col.strs != nil {
			for s in col.strs {
				delete(s)
			}
			delete(col.strs)
		}
	}
	delete(ds.columns)
	delete(ds.name)
	delete(ds.path)
	if ds.map_cache.rows != nil {
		delete(ds.map_cache.rows)
		delete(ds.map_cache.lat)
		delete(ds.map_cache.lon)
		delete(ds.map_cache.time)
		delete(ds.map_cache.cols)
	}
	ds^ = {}
}

equal_ci :: proc(a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	la := strings.to_lower(a, context.temp_allocator)
	lb := strings.to_lower(b, context.temp_allocator)
	return la == lb
}

ds_column :: proc(ds: ^Dataset, name: string) -> ^Column {
	for &col in ds.columns {
		if equal_ci(col.name, name) {
			return &col
		}
	}
	return nil
}

// Numeric values of a column (NaN where a cell was non-numeric / empty).
ds_values :: proc(col: ^Column) -> []f64 {
	if col == nil {
		return nil
	}
	return col.floats
}

// Whether the column holds ISO timestamps (used to pick a time x-axis).
is_time_column :: proc(col: ^Column) -> bool {
	if col == nil || col.type != .Str {
		return false
	}
	name := strings.to_lower(col.name, context.temp_allocator)
	switch name {
	case "time", "timestamp", "iso_timestamp", "datetime", "date", "iso8601", "ts", "utc":
		return true
	case:
		return false
	}
}

// ISO timestamp (string) cells -> unix seconds (NaN for unparseable cells).
ds_time_seconds :: proc(col: ^Column) -> []f64 {
	if col == nil || col.strs == nil {
		return nil
	}
	out := make([]f64, len(col.strs), context.temp_allocator)
	for s, i in col.strs {
		d, _, _, consumed := time.iso8601_to_components(s)
		if consumed == 0 || consumed != len(s) {
			out[i] = f64_nan()
			continue
		}
		t, ok := time.datetime_to_time(d)
		out[i] = f64(time.time_to_unix(t)) if ok else f64_nan()
	}
	return out
}

// Column helpers used for time series.
time_column_from_ds :: proc(ds: ^Dataset) -> ^Column {
	for &col in ds.columns {
		if is_time_column(&col) {
			return &col
		}
	}
	return nil
}

// Auto-detects latitude / longitude columns by name (case-insensitive).
ds_find_lat_lon :: proc(ds: ^Dataset) -> (lat, lon: ^Column, ok: bool) {
	lat_names := [?]string{"latitudes", "latitude", "lat"}
	lon_names := [?]string{"longitudes", "longitude", "lon", "lng"}
	for name in lat_names {
		for &c in ds.columns {
			if equal_ci(c.name, name) {
				lat = &c
				break
			}
		}
		if lat != nil {break}
	}
	for name in lon_names {
		for &c in ds.columns {
			if equal_ci(c.name, name) {
				lon = &c
				break
			}
		}
		if lon != nil {break}
	}
	ok = lat != nil && lon != nil
	return
}

// Builds the sampled lat/lon arrays for the map and auto-detects the columns
// shown in the hover tooltip (everything except the lat/lon/time columns).
// Results are cached per (lat, lon) column pair; long tracks are stride-sampled
// so huge files stay cheap to draw and hover.
MAX_MAP_POINTS :: 8000
dataset_ensure_map_cache :: proc(ds: ^Dataset, lat, lon: ^Column) -> (^Map_Cache, bool) {
	if lat == nil || lon == nil {
		return nil, false
	}
	lat_idx := int(uintptr(lat) - uintptr(&ds.columns[0])) / size_of(Column)
	lon_idx := int(uintptr(lon) - uintptr(&ds.columns[0])) / size_of(Column)
	marker := lat_idx + len(ds.columns) * lon_idx
	if ds.map_cache.ok && ds.map_cache.marker == marker {
		return &ds.map_cache, true
	}

	if ds.map_cache.rows != nil {
		delete(ds.map_cache.rows)
		delete(ds.map_cache.lat)
		delete(ds.map_cache.lon)
		delete(ds.map_cache.time)
		delete(ds.map_cache.cols)
	}
	ds.map_cache = {}

	n := ds.n_rows
	latf := ds_values(lat)
	lonf := ds_values(lon)
	time_col := time_column_from_ds(ds)
	secs: []f64
	if time_col != nil {
		secs = ds_time_seconds(time_col)
	}
	stride := (n + MAX_MAP_POINTS - 1) / MAX_MAP_POINTS if n > MAX_MAP_POINTS else 1
	count := (n + stride - 1) / stride

	rows := make([]int, count, context.allocator)
	olat := make([]f64, count, context.allocator)
	olon := make([]f64, count, context.allocator)
	otime := make([]f64, count, context.allocator)
	for i := 0; i < n; i += stride {
		j := i / stride
		rows[j] = i
		olat[j] = latf[i]
		olon[j] = lonf[i]
		otime[j] = f64_nan()
		if secs != nil && !math.is_nan(secs[i]) {
			otime[j] = secs[i]
		}
	}

	// Tooltip columns: numeric/string columns except the lat/lon/time columns.
	cols := make([dynamic]int, 0, len(ds.columns), context.allocator)
	for &c, ci in ds.columns {
		if ci == lat_idx || ci == lon_idx {
			continue
		}
		if &c == time_col {
			continue
		}
		append(&cols, ci)
	}

	ds.map_cache = Map_Cache {
		rows   = rows,
		lat    = olat,
		lon    = olon,
		time   = otime,
		cols   = cols[:],
		marker = marker,
		ok     = true,
	}
	return &ds.map_cache, true
}

// --- CSV loading ------------------------------------------------------------

load_csv_dataset :: proc(path, display_name: string) -> (^Dataset, bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return nil, false
	}
	defer delete(data)

	r: csv.Reader
	csv.reader_init_with_string(&r, string(data), context.allocator)
	defer csv.reader_destroy(&r)

	header, herr := csv.read(&r, context.allocator)
	if herr != nil || len(header) == 0 {
		return nil, false
	}
	// Order matters: defers run LIFO, so free the string contents before the
	// slice backing.
	defer delete(header)
	defer for h in header {
		delete(h)
	}

	ds := new(Dataset)
	ds.name = strings.clone(display_name)
	ds.path = strings.clone(path)
	ds.columns = make([]Column, len(header))
	for h, i in header {
		ds.columns[i].name = strings.clone(h)
	}

	// Column raw string storage during the streaming pass.
	raws := make([dynamic][dynamic]string, len(header), len(header), context.allocator)
	// Order matters: defers run LIFO, so free the column contents first and the
	// outer backing last.
	defer delete(raws)
	defer for col in raws {
		for s in col {
			delete(s)
		}
		delete(col)
	}

	for {
		rec, rerr := csv.read(&r, context.allocator)
		got_eof := rerr != nil && csv.is_io_error(rerr, .EOF)
		if len(rec) == 0 {
			delete(rec)
			if rerr != nil {break}
			continue
		}
		for j in 0 ..< len(header) {
			if j >= len(rec) {
				append(&raws[j], strings.clone(""))
				continue
			}
			// Transfer ownership of the cell string into the column store.
			append(&raws[j], rec[j])
			rec[j] = ""
		}
		for j := len(header); j < len(rec); j += 1 {
			delete(rec[j])
		}
		delete(rec)
		if rerr != nil && !got_eof {break}
		if got_eof {break}
	}

	ds.n_rows = len(raws[0]) if len(raws) > 0 else 0
	for &col, ci in ds.columns {
		raw := raws[ci]
		f := make([dynamic]f64, 0, len(raw), context.allocator)
		s := make([dynamic]string, 0, len(raw), context.allocator)
		all_num := true
		all_bool := true
		for cell in raw {
			cell_str, ok := raw_cell_string(cell)
			all_num, all_bool = append_cell(&f, &s, cell_str, ok, all_num, all_bool)
		}
		col.floats = f[:]
		col.strs = s[:]
		finalize_column(&col, all_num, all_bool)
	}
	return ds, true
}

// --- JSON loading -----------------------------------------------------------

load_json_dataset :: proc(path, display_name: string) -> (^Dataset, bool) {
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

	ds := new(Dataset)
	ds.name = strings.clone(display_name)
	ds.path = strings.clone(path)

	#partial switch v in val {
	case json.Array:
		if !json_aos_into_dataset(ds, v) {
			dataset_destroy(ds)
			return nil, false
		}
	case json.Object:
		if !json_object_into_dataset(ds, v) {
			dataset_destroy(ds)
			return nil, false
		}
	case:
		dataset_destroy(ds)
		return nil, false
	}
	if ds.n_rows == 0 || len(ds.columns) == 0 {
		dataset_destroy(ds)
		return nil, false
	}
	return ds, true
}

// Top-level object: either SoA (keys -> scalar arrays) or a container holding
// a nested array of objects (AoS under a key such as "results").
json_object_into_dataset :: proc(ds: ^Dataset, obj: json.Object) -> bool {
	// Prefer a nested AoS container.
	keys := make([dynamic]string, context.temp_allocator)
	defer delete(keys)
	for k, sub in obj {
		if arr, ok := sub.(json.Array); ok && len(arr) > 0 {
			if _, is_obj := arr[0].(json.Object); is_obj {
				if json_aos_into_dataset(ds, arr) {
					return true
				}
			}
		}
	}

	// SoA: collect keys whose values are arrays of scalars.
	n_rows := 0
	for k, sub in obj {
		arr, ok := sub.(json.Array)
		if !ok || len(arr) == 0 {
			continue
		}
		if json_array_is_scalar(arr[0]) {
			append(&keys, k)
			n_rows = max(n_rows, len(arr))
		}
	}
	if len(keys) == 0 || n_rows == 0 {
		return false
	}
	sort.quick_sort_proc(keys[:], proc(a, b: string) -> int {return strings.compare(a, b)})

	ds.n_rows = n_rows
	ds.columns = make([]Column, len(keys))
	for k, i in keys {
		ds.columns[i].name = strings.clone(k)
		arr := obj[k].(json.Array)
		col := &ds.columns[i]
		f := make([dynamic]f64, 0, n_rows, context.allocator)
		s := make([dynamic]string, 0, n_rows, context.allocator)
		all_num := true
		all_bool := true
		for row in 0 ..< n_rows {
			if row < len(arr) {
				all_num, all_bool = json_append_cell(&f, &s, arr[row], all_num, all_bool)
			} else {
				append(&f, f64_nan())
				append(&s, strings.clone(""))
				all_num = false
				all_bool = false
			}
		}
		col.floats = f[:]
		col.strs = s[:]
		finalize_column(col, all_num, all_bool)
	}
	return true
}

// Array of objects: rows = elements, columns = union of keys (sorted).
json_aos_into_dataset :: proc(ds: ^Dataset, arr: json.Array) -> bool {
	n := len(arr)
	if n == 0 {
		return false
	}

	// Discover keys from the first elements; stop early once stable so huge
	// arrays never get scanned twice.
	key_set := make(map[string]bool, context.temp_allocator)
	keys := make([dynamic]string, context.temp_allocator)
	limit := min(n, 512)
	stable := 0
	for i in 0 ..< limit {
		obj, ok := arr[i].(json.Object)
		if !ok {
			continue
		}
		if len(obj) == 0 {
			continue
		}
		added := false
		for k in obj {
			if !key_set[k] {
				key_set[k] = true
				append(&keys, k)
				added = true
			}
		}
		if added {
			stable = 0
		} else {
			stable += 1
		}
		if stable >= 16 {
			break
		}
	}
	if len(keys) == 0 {
		return false
	}
	sort.quick_sort_proc(keys[:], proc(a, b: string) -> int {return strings.compare(a, b)})

	ds.n_rows = n
	ds.columns = make([]Column, len(keys))
	for k, i in keys {
		ds.columns[i].name = strings.clone(k)
		col := &ds.columns[i]
		f := make([dynamic]f64, 0, n, context.allocator)
		s := make([dynamic]string, 0, n, context.allocator)
		all_num := true
		all_bool := true
		for row in 0 ..< n {
			obj, ok := arr[row].(json.Object)
			if ok {
				if v, ok2 := obj[k]; ok2 {
					all_num, all_bool = json_append_cell(&f, &s, v, all_num, all_bool)
					continue
				}
			}
			append(&f, f64_nan())
			append(&s, strings.clone(""))
			all_num = false
			all_bool = false
		}
		col.floats = f[:]
		col.strs = s[:]
		finalize_column(col, all_num, all_bool)
	}
	return true
}

json_array_is_scalar :: proc(v: json.Value) -> bool {
	#partial switch v in v {
	case json.Object, json.Array:
		return false
	case:
		return true
	}
}

// --- column building helpers ------------------------------------------------

raw_cell_string :: proc(cell: string) -> (s: string, ok: bool) {
	t := strings.trim_space(cell)
	if len(t) == 0 {
		return "", false
	}
	return t, true
}

// Appends one cell value to a column under construction, updating the
// all-numeric / all-boolean classification flags.
append_cell :: proc(
	floats: ^[dynamic]f64,
	strs: ^[dynamic]string,
	cell: string,
	ok: bool,
	all_num, all_bool: bool,
) -> (bool, bool) {
	if !ok {
		append(floats, f64_nan())
		append(strs, strings.clone(""))
		return false, false
	}
	if is_bool_token(cell) {
		append(floats, 1.0 if bool_token_value(cell) else 0.0)
		append(strs, strings.clone(""))
		return false, all_bool
	}
	if f, parse_ok := strconv.parse_f64(cell); parse_ok {
		append(floats, f)
		append(strs, strings.clone(""))
		return all_num, false
	}
	append(floats, f64_nan())
	append(strs, strings.clone(cell))
	return false, false
}

json_append_cell :: proc(
	floats: ^[dynamic]f64,
	strs: ^[dynamic]string,
	v: json.Value,
	all_num, all_bool: bool,
) -> (bool, bool) {
	#partial switch c in v {
	case json.Null:
		append(floats, f64_nan())
		append(strs, strings.clone(""))
		return false, false
	case json.Integer:
		append(floats, f64(c))
		append(strs, strings.clone(""))
		return all_num, false
	case json.Float:
		append(floats, c)
		append(strs, strings.clone(""))
		return all_num, false
	case json.Boolean:
		append(floats, 1.0 if c else 0.0)
		append(strs, strings.clone(""))
		return false, all_bool
	case json.String:
		return append_cell(floats, strs, string(c), true, all_num, all_bool)
	case json.Object, json.Array:
		append(floats, f64_nan())
		append(strs, strings.clone(""))
		return false, false
	}
	unreachable()
}

finalize_column :: proc(col: ^Column, all_num, all_bool: bool) {
	// Strings were filled during the pass; free them unless the column is Str.
	if all_bool || all_num {
		for s in col.strs {
			delete(s)
		}
		delete(col.strs)
		col.strs = nil
	}
	col.type = .Bool if all_bool else (.Float if all_num else .Str)
}

is_bool_token :: proc(t: string) -> bool {
	lower := strings.to_lower(t, context.temp_allocator)
	switch lower {
	case "true", "false", "yes", "no", "on", "off", "1", "0":
		return true
	case:
		return false
	}
}

bool_token_value :: proc(t: string) -> bool {
	lower := strings.to_lower(t, context.temp_allocator)
	switch lower {
	case "true", "yes", "on", "1":
		return true
	case:
		return false
	}
}

// Dispatch by file extension.
load_dataset :: proc(path: string) -> (^Dataset, bool) {
	ext := file_extension(path)
	base := file_base_name(path)
	switch ext {
	case ".csv":
		return load_csv_dataset(path, base)
	case ".json":
		return load_json_dataset(path, base)
	case:
		return nil, false
	}
}

file_extension :: proc(path: string) -> string {
	// naive lower-cased extension
	name := path
	if slash := strings.last_index_any(name, "/\\"); slash >= 0 {
		name = name[slash + 1:]
	}
	if dot := strings.last_index(name, "."); dot >= 0 {
		return strings.to_lower(name[dot:], context.temp_allocator)
	}
	return ""
}

file_base_name :: proc(path: string) -> string {
	name := path
	if slash := strings.last_index_any(name, "/\\"); slash >= 0 {
		name = name[slash + 1:]
	}
	return name
}

// Stride-samples a numeric column into f32 for histogram widgets.
ds_hist_values :: proc(col: ^Column, max_points: int) -> []f32 {
	vals := ds_values(col)
	n := len(vals)
	stride := (n + max_points - 1) / max_points if n > max_points else 1
	out := make([dynamic]f32, 0, (n + stride - 1) / stride, context.temp_allocator)
	for i := 0; i < n; i += stride {
		append(&out, f32(vals[i]))
	}
	return out[:]
}

// Builds x/y point pairs for the line / 2d-histogram widgets.
ds_series_xy :: proc(ds: ^Dataset, x_col, y_col: ^Column, max_points: int) -> [][2]f64 {
	if x_col == nil || y_col == nil {
		return nil
	}
	xv := ds_values(x_col)
	yv := ds_values(y_col)
	n := min(len(xv), len(yv), ds.n_rows)
	if n == 0 {
		return nil
	}
	// If the x column is an ISO time column, use unix seconds.
	x_time: []f64
	if is_time_column(x_col) {
		x_time = ds_time_seconds(x_col)
	}
	stride := (n + max_points - 1) / max_points if n > max_points else 1
	out := make([dynamic][2]f64, 0, (n + stride - 1) / stride, context.temp_allocator)
	for i := 0; i < n; i += stride {
		x := xv[i]
		if x_time != nil {
			x = x_time[i]
		}
		append(&out, [2]f64{x, yv[i]})
	}
	return out[:]
}