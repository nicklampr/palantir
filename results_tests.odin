package palantir

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import rl "vendor:raylib"

YGG_RESULTS_DIR :: "/home/nick/yggdrasil/results"

@(test)
test_load_csv_generic :: proc(t: ^testing.T) {
	path := YGG_RESULTS_DIR + "/test_parse_csv_generic.csv"
	ds, ok := load_csv_dataset(path, "test")
	testing.expect(t, ok, "failed to load csv")
	if !ok {return}
	defer free(ds)
	defer dataset_destroy(ds)

	testing.expect(t, ds.n_rows == 4, "expected 4 rows")
	testing.expect(t, len(ds.columns) == 5, "expected 5 columns")

	lat := ds_column(ds, "latitude")
	testing.expect(t, lat != nil, "latitude column missing")
	if lat != nil {
		// row "broken" has a non-numeric latitude -> the column is Str
		testing.expect(t, lat.type == .Str, "latitude should be Str due to bad cell")
		testing.expect(t, len(lat.floats) == 4, "floats length mismatch")
		testing.expect(t, math_is_nan(lat.floats[2]), "broken cell should be NaN")
	}

age := ds_column(ds, "age")
	testing.expect(t, age != nil, "age column missing")
	if age != nil {
		testing.expect(t, age.type == .Float, "age should be Float (all numeric)")
		testing.expect(t, age.floats[3] == 9.0, "age[3] mismatch")
	}

	active := ds_column(ds, "active")
	testing.expect(t, active != nil, "active column missing")
	if active != nil {
		testing.expect(t, active.type == .Bool, "active should be Bool")
	}

	name := ds_column(ds, "name")
	testing.expect(t, name != nil && name.type == .Str, "name should be Str")
	if name != nil && name.strs != nil {
		testing.expect(t, name.strs[0] == "harbor", "first name mismatch")
	}
}

@(test)
test_load_json_aos :: proc(t: ^testing.T) {
	path := YGG_RESULTS_DIR + "/perf_from_routes_2025.json"
	ds, ok := load_json_dataset(path, "perf")
	testing.expect(t, ok, "failed to load json")
	if !ok {return}
	defer free(ds)
	defer dataset_destroy(ds)

	testing.expect(t, ds.n_rows == 150, "expected 150 rows")
	longitude := ds_column(ds, "longitude")
	testing.expect(t, longitude != nil, "longitude column missing")
	if longitude != nil {
		testing.expect(t, longitude.type == .Float, "longitude should be Float")
		testing.expect(t, abs_f64(longitude.floats[0] - 129.08958435) < 1e-4, "first longitude mismatch")
	}

	ts := ds_column(ds, "iso_timestamp")
	testing.expect(t, ts != nil && ts.type == .Str, "iso_timestamp should be a Str column")
	if ts != nil {
		secs := ds_time_seconds(ts)
		testing.expect(t, len(secs) == 150, "time seconds length")
		// The data file may be regenerated, so derive the expected value from
		// the first row's own timestamp instead of a hardcoded date.
		expected := unix_for_first_row(path)
		testing.expect(t, abs_f64(secs[0] - expected) < 5, "first timestamp unix mismatch")
	}
}

@(test)
test_load_json_soa :: proc(t: ^testing.T) {
	tmp := fmt_tmp_path("soa")
	defer os.remove(tmp)

	content := `{"meta":"ignored","longitude":[1.0,2.0,3.0],"latitude":[10.0,20.0,30.0],"label":["a","b","c"]}`
	err := os.write_entire_file_from_string(tmp, content)
	testing.expect(t, err == nil, "failed to write tmp json")
	if err != nil {return}

	ds, ok := load_json_dataset(tmp, "soa")
	testing.expect(t, ok, "failed to load SoA json")
	if !ok {return}
	defer free(ds)
	defer dataset_destroy(ds)

	testing.expect(t, ds.n_rows == 3, "expected 3 rows")
	testing.expect(t, len(ds.columns) == 3, "expected 3 columns (meta skipped)")

	lon := ds_column(ds, "longitude")
	testing.expect(t, lon != nil && lon.type == .Float, "longitude should be Float")
	if lon != nil {
		testing.expect(t, lon.floats[2] == 3.0, "lon[2] mismatch")
	}
	label := ds_column(ds, "label")
	testing.expect(t, label != nil && label.type == .Str, "label should be Str")
}

@(test)
test_load_json_nested_aos :: proc(t: ^testing.T) {
	tmp := fmt_tmp_path("nested")
	defer os.remove(tmp)

	content := `{"results":[{"x":1.0,"y":2.0},{"x":3.0,"y":4.0}],"n":2}`
	err := os.write_entire_file_from_string(tmp, content)
	testing.expect(t, err == nil, "failed to write tmp json")
	if err != nil {return}

	ds, ok := load_json_dataset(tmp, "nested")
	testing.expect(t, ok, "failed to load nested AoS json")
	if !ok {return}
	defer free(ds)
	defer dataset_destroy(ds)

	testing.expect(t, ds.n_rows == 2, "expected 2 rows")
	testing.expect(t, len(ds.columns) == 2, "expected 2 columns")
	x := ds_column(ds, "x")
	if x != nil {
		testing.expect(t, x.floats[1] == 3.0, "x[1] mismatch")
	}
}

@(test)
test_lat_lon_detection :: proc(t: ^testing.T) {
	path := YGG_RESULTS_DIR + "/belgium_to_south_africa.csv"
	ds, ok := load_csv_dataset(path, "route")
	testing.expect(t, ok, "failed to load csv")
	if !ok {return}
	defer free(ds)
	defer dataset_destroy(ds)

	lat, lon, found := ds_find_lat_lon(ds)
	testing.expect(t, found, "lat/lon should be detected")
	if found {
		testing.expect(t, lat.name == "latitudes", "lat column name")
		testing.expect(t, lon.name == "longitudes", "lon column name")
	}
}

@(test)
test_map_cache_generic :: proc(t: ^testing.T) {
	path := YGG_RESULTS_DIR + "/belgium_to_south_africa.csv"
	ds, ok := load_csv_dataset(path, "route")
	testing.expect(t, ok, "failed to load csv")
	if !ok {return}
	defer free(ds)
	defer dataset_destroy(ds)

	lat, lon, found := ds_find_lat_lon(ds)
	testing.expect(t, found, "lat/lon auto-detect")
	if !found {return}

	cache, built := dataset_ensure_map_cache(ds, lat, lon)
	testing.expect(t, built && cache != nil, "map cache built")
	if cache == nil {return}

	testing.expect(t, len(cache.lat) == ds.n_rows, "cache length matches rows")
	testing.expect(t, len(cache.lon) == ds.n_rows, "cache lon length matches rows")
	testing.expect(t, abs_f64(cache.lat[0] - 51.51821) < 1e-3, "first sampled latitude")

	// Tooltip columns must never include the lat/lon columns.
	for ci in cache.cols {
		c := &ds.columns[ci]
		testing.expect(t, c != lat && c != lon, "tooltip column is not lat/lon")
	}
}

@(test)
test_open_path_handling :: proc(t: ^testing.T) {
	app: App
	results_init(&app)
	defer results_destroy(&app)

	results_set_root(&app, "/tmp")

	// Non-result file type -> friendly message, nothing loaded.
	results_open_path(&app, "/home/nick/palantir/gui.odin")
	testing.expect(t, app.results.msg != "", "expected a message for non-result file")
	testing.expect(t, len(app.results.datasets) == 0, "no dataset should load for invalid type")

	results_clear_msg(&app)

	// Valid CSV -> browsed to its folder and selected/loaded.
	results_open_path(&app, YGG_RESULTS_DIR + "/belgium_to_south_africa.csv")
	testing.expect(t, len(app.results.datasets) == 1, "csv should load")
	testing.expect(t, app.results.active_ds == 0, "active dataset should be set")
	testing.expect(t, app.results.show_recents == false, "should leave recents view")

	// Missing path -> friendly message.
	results_open_path(&app, "/nonexistent/nope.csv")
	testing.expect(t, app.results.msg != "", "expected a message for a missing path")

	for p in app.recents {
		delete(p)
	}
	delete(app.recents)
}

@(test)
test_folder_palette_selection :: proc(t: ^testing.T) {
	app: App
	results_init(&app)
	palette_init(&app.palette, nil, nil)
	defer results_destroy(&app)
	defer palette_destroy(&app.palette)
	defer {
		for p in app.recents {delete(p)}
		delete(app.recents)
		for fc in app.palette_folder_children {
			delete(fc.name)
			delete(fc.description)
		}
		delete(app.palette_folder_children)
	}

	base := fmt.tprintf("/tmp/palantir_folder_test_%d", os.get_pid())
	sub := fmt.tprintf("%s/subdir", base)
	testing.expect(t, os.make_directory(base) == nil, "create temp dir")
	testing.expect(t, os.make_directory(sub) == nil, "create temp subdir")
	defer {
		os.remove_all(sub)
		os.remove_all(base)
	}

	results_set_root(&app, base)
	testing.expect(t, len(app.recents) >= 1, "browsed folder should be recorded as a recent")
	if len(app.recents) >= 1 {
		testing.expect(t, app.recents[0] == base, "most recent folder is the browsed root")
	}

	open_folder_palette(&app)
	testing.expect(t, app.palette.open, "palette should be open")
	testing.expect(t, len(app.palette_folder_children) > 0, "folder list copied into the palette")
	if len(app.palette_folder_children) == 0 {
		return
	}
	// The palette must own a copy, never borrow `results.folder_cmds`, so that
	// selecting a folder (which rescans and rebuilds folder_cmds) can't dangle.
	testing.expect(
		t,
		&app.palette_folder_children[0] != &app.results.folder_cmds[0],
		"palette must own a copy of the folder list",
	)

	// Selecting the parent entry ("..") must navigate without dangling.
	results_handle_folder_select(&app, 0)
	testing.expect(t, app.results.root == "/tmp", "navigated to parent folder")
}

@(test)
test_path_completion :: proc(t: ^testing.T) {
	app: App
	results_init(&app)
	defer results_destroy(&app)
	defer {
		for p in app.recents {delete(p)}
		delete(app.recents)
	}

	base := fmt.tprintf("/tmp/palantir_complete_test_%d", os.get_pid())
	sub := fmt.tprintf("%s/subdir_unique", base)
	testing.expect(t, os.make_directory(base) == nil, "create temp dir")
	testing.expect(t, os.make_directory(sub) == nil, "create temp subdir")
	defer {
		os.remove_all(sub)
		os.remove_all(base)
	}

	results_set_root(&app, base)

	// Type a partial segment and Tab-complete it against the browsed folder.
	prefix := "subdir_un"
	for i in 0 ..< len(prefix) {
		app.results.path_buf[i] = prefix[i]
	}
	app.results.path_len = len(prefix)
	app.results.path_buf[app.results.path_len] = 0

	results_complete_path(&app)
	completed := string(app.results.path_buf[:app.results.path_len])
	testing.expect(t, completed == "subdir_unique/", "tab completes a unique directory with a trailing slash")
}

@(test)
test_recent_folder_navigation :: proc(t: ^testing.T) {
	app: App
	results_init(&app)
	defer results_destroy(&app)
	defer {
		for p in app.recents {delete(p)}
		delete(app.recents)
	}

	base := fmt.tprintf("/tmp/palantir_recent_test_%d", os.get_pid())
	testing.expect(t, os.make_directory(base) == nil, "create temp dir")
	defer os.remove_all(base)

	// First navigation records the folder.
	results_set_root(&app, base)
	testing.expect(t, len(app.recents) == 1 && app.recents[0] == base, "root recorded as a recent folder")

	// Opening that recent passes a slice into app.recents; it must not crash
	// (regression for the use-after-free) and must navigate to the folder.
	results_open_recent(&app, 0)
	testing.expect(t, app.results.root == base, "recent folder navigated")
	testing.expect(t, len(app.recents) >= 1 && app.recents[0] == base, "recents remain valid")
}

@(test)
test_go_up_no_uaf :: proc(t: ^testing.T) {
	app: App
	results_init(&app)
	defer results_destroy(&app)
	defer {
		for p in app.recents {delete(p)}
		delete(app.recents)
	}

	base := fmt.tprintf("/tmp/palantir_up_test_%d", os.get_pid())
	sub := fmt.tprintf("%s/sub", base)
	testing.expect(t, os.make_directory(base) == nil, "create temp dir")
	testing.expect(t, os.make_directory(sub) == nil, "create temp subdir")
	defer {
		os.remove_all(sub)
		os.remove_all(base)
	}

	results_set_root(&app, sub)
	testing.expect(t, app.results.root == sub, "root is the nested folder")
	results_go_up(&app)
	testing.expect(t, app.results.root == base, "go up navigates to parent")
}

@(test)
test_palette_tab_complete :: proc(t: ^testing.T) {
	p: Command_Palette
	defer palette_destroy(&p)
	cmds := [?]Palette_Command {
		{name = "subdir", description = "a folder"},
		{name = "..", description = "parent"},
	}
	palette_init(&p, cmds[:], nil)
	palette_open_it(&p)
	palette_refresh_matches(&p)
	testing.expect(t, len(p.matches) == 2, "empty query matches every command")
	p.selected = 0
	palette_complete_selected(&p)
	testing.expect(t, palette_query_string(&p) == "subdir", "tab completes the query to the selected name")
}

@(test)
test_path_backspace_boundary :: proc(t: ^testing.T) {
	app: App
	results_init(&app)
	defer results_destroy(&app)
	defer {
		for p in app.recents {delete(p)}
		delete(app.recents)
	}

	base := fmt.tprintf("/tmp/palantir_bs_test_%d", os.get_pid())
	sub := fmt.tprintf("%s/sub", base)
	testing.expect(t, os.make_directory(base) == nil, "create temp dir")
	testing.expect(t, os.make_directory(sub) == nil, "create temp subdir")
	defer {
		os.remove_all(sub)
		os.remove_all(base)
	}

	results_set_root(&app, base)
	// Simulate the path box holding "<base>/sub/".
	text := fmt.tprintf("%s/", sub)
	app.results.path_len = 0
	for i in 0 ..< len(text) {
		app.results.path_buf[i] = text[i]
	}
	app.results.path_len = len(text)
	app.results.path_buf[app.results.path_len] = 0

	handled := path_input_backspace(&app, string(app.results.path_buf[:app.results.path_len]))
	testing.expect(t, handled, "backspace at a folder boundary is handled")
	testing.expect(t, app.results.root == base, "backspace navigated up to the parent")
}

@(test)
test_folder_palette_real_select :: proc(t: ^testing.T) {
	// Drive the exact GUI path: the palette's on_select is `on_palette_select`,
	// which dispatches on the global `default_app`. Set it up and reset after.
	default_app = {}
	defer default_app = {}
	app := &default_app

	results_init(app)
	palette_init(&app.palette, nil, on_palette_select)
	defer {
		results_destroy(app)
		palette_destroy(&app.palette)
		for p in app.recents {delete(p)}
		delete(app.recents)
		delete(app.palette_root)
		for c in app.palette_recent_children {
			delete(c.name)
			delete(c.description)
		}
		delete(app.palette_recent_children)
		for fc in app.palette_folder_children {
			delete(fc.name)
			delete(fc.description)
		}
		delete(app.palette_folder_children)
	}

	base := fmt.tprintf("/tmp/palantir_real_pal_%d", os.get_pid())
	sub1 := fmt.tprintf("%s/sub1", base)
	testing.expect(t, os.make_directory(base) == nil, "create temp dir")
	testing.expect(t, os.make_directory(sub1) == nil, "create temp subdir")
	defer {
		os.remove_all(sub1)
		os.remove_all(base)
	}

	results_set_root(app, base)
	open_folder_palette(app)
	testing.expect(t, app.palette.open, "palette open")
	testing.expect(t, len(app.palette_folder_children) >= 2, "folder list has parent + subdirs")

	// Select the first subdirectory entry (".." is index 0) via palette_activate,
	// the same code path an Enter press takes.
	app.palette.selected = 1
	palette_refresh_matches(&app.palette)
	testing.expect(t, len(app.palette.matches) >= 2, "matches reflect the folder list")
	palette_activate(&app.palette, app.palette.matches[1])
	testing.expect(t, app.results.root == sub1, "folder palette navigated into the selected subdirectory")

	// Simulate the next frame's recents_dirty handling (runs while the palette's
	// layer stack is still non-empty after the select closed it).
	refresh_palette_recents(app)

	// Re-open and select again (repeated Ctrl+G cycles).
	results_set_root(app, base)
	open_folder_palette(app)
	if len(app.palette_folder_children) >= 2 {
		app.palette.selected = 1
		palette_refresh_matches(&app.palette)
		if len(app.palette.matches) >= 2 {
			palette_activate(&app.palette, app.palette.matches[1])
		}
	}
	testing.expect(t, true, "repeated folder palette selects did not crash")
}

// Stress-tests repeated Ctrl+G folder-palette open/select cycles (selecting
// every option, resetting, and running the recents rebuild) to flush out any
// double-free or use-after-free in the folder-palette lifetime handling.
@(test)
test_folder_palette_stress :: proc(t: ^testing.T) {
	default_app = {}
	defer default_app = {}
	app := &default_app
	results_init(app)
	palette_init(&app.palette, nil, on_palette_select)
	defer {
		results_destroy(app)
		palette_destroy(&app.palette)
		for p in app.recents {delete(p)}
		delete(app.recents)
		delete(app.palette_root)
		for c in app.palette_recent_children {
			delete(c.name)
			delete(c.description)
		}
		delete(app.palette_recent_children)
		for fc in app.palette_folder_children {
			delete(fc.name)
			delete(fc.description)
		}
		delete(app.palette_folder_children)
	}

	base := fmt.tprintf("/tmp/palantir_stress_%d", os.get_pid())
	sub1 := fmt.tprintf("%s/sub1", base)
	sub2 := fmt.tprintf("%s/sub2", base)
	testing.expect(t, os.make_directory(base) == nil, "create temp dir")
	testing.expect(t, os.make_directory(sub1) == nil, "create sub1")
	testing.expect(t, os.make_directory(sub2) == nil, "create sub2")
	defer {
		os.remove_all(sub1)
		os.remove_all(sub2)
		os.remove_all(base)
	}

	for round in 0 ..< 20 {
		results_set_root(app, base)
		open_folder_palette(app)
		n := len(app.palette_folder_children)
		for j := 0; j < n; j += 1 {
			results_set_root(app, base)
			open_folder_palette(app)
			app.palette.selected = j
			palette_refresh_matches(&app.palette)
			if j < len(app.palette.matches) {
				palette_activate(&app.palette, app.palette.matches[j])
			}
			refresh_palette_recents(app)
		}
	}
	testing.expect(t, true, "folder palette stress cycles completed without memory errors")
}

// --- tiny test helpers ------------------------------------------------------

math_is_nan :: proc(v: f64) -> bool {
	return v != v
}

abs_f64 :: proc(v: f64) -> f64 {
	return v if v >= 0 else -v
}

unix_for_first_row :: proc(path: string) -> f64 {
	data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	if rerr != nil {
		return f64_nan()
	}
	val, perr := json.parse(data, allocator = context.temp_allocator)
	if perr != nil || val == nil {
		return f64_nan()
	}
	arr, arr_ok := val.(json.Array)
	if !arr_ok || len(arr) == 0 {
		return f64_nan()
	}
	first, first_ok := arr[0].(json.Object)
	if !first_ok {
		return f64_nan()
	}
	ts, ts_ok := first["iso_timestamp"].(json.String)
	if !ts_ok {
		return f64_nan()
	}
	d, _, _, consumed := time.iso8601_to_components(ts)
	if consumed != len(ts) {
		return f64_nan()
	}
	t, dt_ok := time.datetime_to_time(d)
	return f64(time.time_to_unix(t)) if dt_ok else f64_nan()
}

fmt_tmp_path :: proc(tag: string) -> string {
	return fmt.tprintf("/tmp/palantir_test_%s_%d.json", tag, os.get_pid())
}

// --- hue / colormap helpers ------------------------------------------------

@(test)
test_hue_series_alignment :: proc(t: ^testing.T) {
	tmp := fmt_tmp_path("hue")
	defer os.remove(tmp)

	content := `[{"x":0.0,"y":1.0,"h":5.0},{"x":1.0,"y":2.0,"h":7.0},{"x":2.0,"y":3.0,"h":9.0},{"x":3.0,"y":4.0,"h":11.0},{"x":4.0,"y":5.0,"h":13.0},{"x":5.0,"y":6.0,"h":15.0},{"x":6.0,"y":7.0,"h":17.0},{"x":7.0,"y":8.0,"h":19.0},{"x":8.0,"y":9.0,"h":21.0},{"x":9.0,"y":10.0,"h":23.0}]`
	err := os.write_entire_file_from_string(tmp, content)
	testing.expect(t, err == nil, "failed to write hue json")
	if err != nil {return}

	ds, ok := load_json_dataset(tmp, "hue")
	if !ok {return}
	defer free(ds)
	defer dataset_destroy(ds)

	xc := ds_column(ds, "x")
	hc := ds_column(ds, "h")
	testing.expect(t, xc != nil && hc != nil, "columns missing")
	if xc == nil || hc == nil {return}

	// Same stride rule -> hue must line up 1:1 with the plotted points.
	max_points := 5
	pts := ds_series_xy(ds, xc, hc, max_points)
	hue := ds_series_hue(ds, hc, max_points)
	testing.expect(t, len(hue) == len(pts), "hue length must match point count")
	if len(hue) != len(pts) {return}
	for k in 0 ..< len(pts) {
		// point.y is sampled from the same index as h, so y == h at each k.
		testing.expect(t, abs_f64(pts[k][1] - hue[k]) < 1e-9, "hue misaligned with point")
	}

	series := []PlotSeries{{points = pts, hue = hue}}
	lo, hi, ok_dom := hue_domain_of(series)
	testing.expect(t, ok_dom, "hue domain should be found")
	// stride sampling visits indices 0,2,4,6,8 -> h = 5,9,13,17,21
	testing.expect(t, abs_f64(lo - 5) < 1e-9 && abs_f64(hi - 21) < 1e-9, "hue domain bounds")

	black := rl.Color{0, 0, 0, 255}
	white := rl.Color{255, 255, 255, 255}
	c_lo := hue_lookup(lo, hi, lo, black, white)
	c_hi := hue_lookup(lo, hi, hi, black, white)
	testing.expect(t, c_lo.r == 0 && c_lo.g == 0, "low hue -> low color")
	testing.expect(t, c_hi.r == 255 && c_hi.g == 255, "high hue -> high color")
}

@(test)
test_fuzzy_words_match :: proc(t: ^testing.T) {
	testing.expect(t, fuzzy_words_match("latitude", ""), "empty query matches everything")
	testing.expect(t, fuzzy_words_match("latitude", "lat"), "single term")
	testing.expect(t, fuzzy_words_match("latitude", "LAT"), "case insensitive")
	// every term must match somewhere in the name (order-free words)
	testing.expect(t, fuzzy_words_match("latitude calc", "calc lat"), "all words match anywhere")
	testing.expect(t, fuzzy_words_match("latitude", "la ti tu de"), "multi-term substring")
	testing.expect(t, !fuzzy_words_match("latitude", "lon"), "missing term rejects")
	testing.expect(t, !fuzzy_words_match("latitude", "lat lon"), "one missing term rejects")
}

@(test)
test_hue_nan_ignored_in_domain :: proc(t: ^testing.T) {
	series := []PlotSeries {
		{
			points = [][2]f64{{0, 0}, {1, 1}},
			hue    = []f64{f64_nan(), 4},
		},
	}
	lo, hi, ok := hue_domain_of(series)
	testing.expect(t, ok, "domain found despite NaN")
	// NaN excluded; the single surviving value makes a degenerate domain that
	// hue_domain_of expands by 1 so the colormap never divides by zero.
	testing.expect(t, lo == 4 && hi == 5, "NaN excluded; degenerate domain expanded")
}