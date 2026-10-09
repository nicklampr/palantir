package palantir

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import rl "vendor:raylib"

// Serializes the tests that drive the package-global `default_app` (the palette
// callback dispatches on it), so they never clobber each other under the
// parallel test runner.
global_app_test_mutex: sync.Mutex

@(test)
test_walkthrough_palette_command :: proc(t: ^testing.T) {
	sync.mutex_lock(&global_app_test_mutex)
	defer sync.mutex_unlock(&global_app_test_mutex)
	default_app = {}
	defer default_app = {}
	app := &default_app
	palette_init(&app.palette, gui_commands[:], on_palette_select)
	defer palette_destroy(&app.palette)
	palette_open_it(&app.palette)
	app.walkthrough_scroll = 100

	found := false
	for cmd, i in gui_commands {
		if GuiCommand(uintptr(cmd.user_data)) == .show_walkthrough {
			palette_activate(&app.palette, i)
			found = true
			break
		}
	}
	testing.expect(t, found, "walkthrough is in the command palette")
	testing.expect(t, app.walkthrough_open, "selecting walkthrough opens the dialog")
	testing.expect(t, app.walkthrough_scroll == 0, "opening walkthrough resets its scroll position")
	testing.expect(t, !app.palette.open, "palette closes when walkthrough opens")
}

@(test)
test_panel_visibility_settings :: proc(t: ^testing.T) {
	defaults := default_settings()
	testing.expect(t, !defaults.left_panel_hidden && !defaults.bottom_panel_hidden, "panels are visible with older settings")

	saved := default_settings()
	saved.left_panel_hidden = true
	saved.bottom_panel_hidden = true
	saved.left_panel_width = 420
	saved.bottom_panel_height = 260
	data, err := json.marshal(saved)
	testing.expect(t, err == nil, "serialize panel visibility")
	if err != nil {return}
	defer delete(data)

	restored := default_settings()
	unmarshal_err := json.unmarshal(data, &restored)
	testing.expect(t, unmarshal_err == nil, "deserialize panel visibility")
	testing.expect(t, restored.left_panel_hidden && restored.bottom_panel_hidden, "hidden panels survive a settings roundtrip")
	testing.expect(t, restored.left_panel_width == 420 && restored.bottom_panel_height == 260, "dock sizes survive a settings roundtrip")

	app: App
	results_init(&app)
	defer results_destroy(&app)
	default_left, default_bottom := results_dock_sizes(&app.results, 1920, 1080, 56, 1)
	testing.expect(t, default_left == 320 && default_bottom == 160, "old settings retain the original dock sizes")
	app.results.left_panel_width = restored.left_panel_width
	app.results.bottom_panel_height = restored.bottom_panel_height
	left_w, bottom_h := results_dock_sizes(&app.results, 1920, 1080, 56, 1)
	testing.expect(t, left_w == 420 && bottom_h == 260, "saved sizes determine the panel layout")
	left_w, bottom_h = results_dock_sizes(&app.results, 3840, 2160, 112, 2)
	testing.expect(t, left_w == 840 && bottom_h == 520, "dock sizes follow UI zoom")

	app.results.left_panel_width = 9000
	app.results.bottom_panel_height = 9000
	left_w, bottom_h = results_dock_sizes(&app.results, 800, 600, 56, 1)
	_, left_max, _, bottom_max := results_dock_limits(800, 600, 56, 1)
	testing.expect(t, left_w == left_max && bottom_h == bottom_max, "resizing leaves room for the plot")
	app.results.left_panel_width = 1
	app.results.bottom_panel_height = 1
	left_w, bottom_h = results_dock_sizes(&app.results, 800, 600, 56, 1)
	left_min, _, bottom_min, _ := results_dock_limits(800, 600, 56, 1)
	testing.expect(t, left_w == left_min && bottom_h == bottom_min, "resizing keeps both docks usable")

	results_toggle_left_panel(&app)
	results_toggle_bottom_panel(&app)
	testing.expect(t, !app.results.show_left_panel && !app.results.show_bottom_panel, "panel toggles hide both panels")
	testing.expect(t, app.results.left_panel_width == 1 && app.results.bottom_panel_height == 1, "hiding panels retains their preferred sizes")
}

@(test)
test_default_plot_selection :: proc(t: ^testing.T) {
	settings := default_settings()
	testing.expect(t, settings.plot_id == PLOT_SCATTER, "new settings should default to a 2D scatter plot")

	saved_settings := default_settings()
	saved_settings.plot_id = PLOT_HIST
	data, marshal_err := json.marshal(saved_settings)
	testing.expect(t, marshal_err == nil, "could not serialize saved plot choice")
	if marshal_err == nil {
		defer delete(data)
		restored_settings := default_settings()
		unmarshal_err := json.unmarshal(data, &restored_settings)
		testing.expect(
			t,
			unmarshal_err == nil && restored_settings.plot_id == PLOT_HIST,
			"saved plot choice should override the fresh default",
		)
	}

	app: App
	results_init(&app)
	defer results_destroy(&app)
	testing.expect(t, app.results.plot.id == PLOT_SCATTER, "new results state should default to a 2D scatter plot")
	testing.expect(t, app.results.plot.contour_levels == CONTOUR_LEVEL_COUNT, "contour plot defaults to seven levels")
}

@(test)
test_plot_zoom_update :: proc(t: ^testing.T) {
	state: Plot_Zoom_State
	x_min, x_max, y_min, y_max := plot_zoom_update(
		&state,
		0,
		10,
		0,
		20,
		0.25,
		0.75,
		0,
		false,
	)
	testing.expect(t, x_min == 0 && x_max == 10 && y_min == 0 && y_max == 20, "initial viewport fits all data")

	x_min, x_max, y_min, y_max = plot_zoom_update(
		&state,
		0,
		10,
		0,
		20,
		0.25,
		0.75,
		1,
		false,
	)
	testing.expect(t, abs(x_max-x_min-10/1.2) < 1e-9, "wheel zoom changes the horizontal range")
	testing.expect(t, abs(y_max-y_min-20/1.2) < 1e-9, "wheel zoom changes the vertical range")
	testing.expect(t, abs(x_min+0.25*(x_max-x_min)-2.5) < 1e-9, "cursor x coordinate stays anchored")
	testing.expect(t, abs(y_min+0.75*(y_max-y_min)-15) < 1e-9, "cursor y coordinate stays anchored")

	x_min, x_max, y_min, y_max = plot_zoom_update(
		&state,
		0,
		10,
		0,
		20,
		0.5,
		0.5,
		0,
		true,
	)
	testing.expect(t, x_min == 0 && x_max == 10 && y_min == 0 && y_max == 20, "reset restores the full data bounds")

	_, _, _, _ = plot_zoom_update(&state, 1, 11, 0, 20, 0.5, 0.5, 0, false)
	testing.expect(t, state.x_min == 1 && state.x_max == 11, "changed data bounds reset the viewport normally")

	state.preserve_on_base_change = true
	_, _, _, _ = plot_zoom_update(&state, 2, 12, 0, 20, 0.5, 0.5, 0, false)
	testing.expect(t, state.x_min == 1 && state.x_max == 11, "refresh preservation keeps the viewport across changed bounds")
	testing.expect(t, !state.preserve_on_base_change, "viewport preservation is one-shot")
	_, _, _, _ = plot_zoom_update(&state, 3, 13, 0, 20, 0.5, 0.5, 0, false)
	testing.expect(t, state.x_min == 3 && state.x_max == 13, "later data-bound changes return to normal fitting")

	_, _, _, _ = plot_zoom_update(&state, 0, 10, 0, 20, 0.5, 0.5, 1, false, true)
	testing.expect(t, abs((state.x_min+state.x_max)*0.5-5) < 1e-9, "centered zoom retains the plot origin")
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

// Some producers double-serialize rows, emitting the same keys twice in every
// object (identical values). json.parse rejects that, so load_json_dataset must
// strip the repeats and load the array-of-structs anyway.
@(test)
test_load_json_aos_duplicate_keys :: proc(t: ^testing.T) {
	tmp := fmt_tmp_path("dupkeys")
	defer os.remove(tmp)

	content := `[{"timestamp":"2025-06-03T19:25:08","latitude":28.237984,"longitude":-89.075165,"route_id":null,"longitude":-89.075165,"latitude":28.237984,"timestamp":"2025-06-03T19:25:08","hs":0.8240368,"missing_wave":false},{"timestamp":"2025-06-03T19:40:17","latitude":28.19939,"longitude":-89.05139,"route_id":null,"longitude":-89.05139,"latitude":28.19939,"timestamp":"2025-06-03T19:40:17","hs":0.8099722,"missing_wave":false}]`
	err := os.write_entire_file_from_string(tmp, content)
	testing.expect(t, err == nil, "failed to write tmp json")
	if err != nil {return}

	ds, ok := load_json_dataset(tmp, "dup")
	testing.expect(t, ok, "failed to load AoS json with duplicate keys")
	if !ok {return}
	defer free(ds)
	defer dataset_destroy(ds)

	testing.expect(t, ds.n_rows == 2, "expected 2 rows")
	testing.expect(t, len(ds.columns) == 6, "expected 6 unique columns")

	latitude := ds_column(ds, "latitude")
	testing.expect(t, latitude != nil && latitude.type == .Float, "latitude should be Float")
	if latitude != nil {
		testing.expect(t, abs_f64(latitude.floats[0] - 28.237984) < 1e-6, "latitude[0] mismatch")
	}
	longitude := ds_column(ds, "longitude")
	testing.expect(t, longitude != nil && longitude.type == .Float, "longitude should be Float")
	if longitude != nil {
		testing.expect(t, abs_f64(longitude.floats[1] - -89.05139) < 1e-6, "longitude[1] mismatch")
	}
	ts := ds_column(ds, "timestamp")
	testing.expect(t, ts != nil && ts.type == .Str, "timestamp should be Str")
}

// The duplicate-key sanitizer must drop repeats at every nesting level and leave
// output that json.parse accepts.
@(test)
test_strip_duplicate_keys :: proc(t: ^testing.T) {
	input := `{"a":1,"a":2,"b":{"x":1,"x":2},"c":[1,2],"a":3}`
	cleaned := json_strip_duplicate_keys(transmute([]byte)input)
	defer delete(cleaned)

	val, perr := json.parse(transmute([]byte)cleaned)
	testing.expect(t, perr == nil, "cleaned json must parse")
	if perr != nil {return}
	defer json.destroy_value(val)

	obj, ok := val.(json.Object)
	testing.expect(t, ok, "expected object")
	if !ok {return}
	testing.expect(t, len(obj) == 3, "expected 3 unique keys")

	// json.parse turns every number into a Float unless parse_integers is set.
	a, aok := obj["a"].(json.Float)
	testing.expect(t, aok && a == 1.0, "kept first a value")
	b, bok := obj["b"].(json.Object)
	testing.expect(t, bok && len(b) == 1, "nested duplicate stripped")
	if bok {
		x, xok := b["x"].(json.Float)
		testing.expect(t, xok && x == 1.0, "nested kept first value")
	}
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
	results_handle_folder_select(&app, app.palette_folder_children[0].description)
	testing.expect(t, app.results.root == "/tmp", "navigated to parent folder")
}

@(test)
test_folder_navigation_clears_file_search :: proc(t: ^testing.T) {
	app: App
	results_init(&app)
	defer results_destroy(&app)
	defer {
		for p in app.recents {delete(p)}
		delete(app.recents)
	}

	base := fmt.tprintf("/tmp/palantir_search_root_%d", os.get_pid())
	sub := fmt.tprintf("%s/subfolder", base)
	file := fmt.tprintf("%s/sample.csv", sub)
	defer os.remove_all(base)
	testing.expect(t, os.make_directory(base) == nil, "create search root")
	testing.expect(t, os.make_directory(sub) == nil, "create matching folder")
	testing.expect(t, os.write_entire_file_from_string(file, "x,y\n1,2\n") == nil, "create file in folder")

	results_set_root(&app, base)
	query := "sub"
	copy(app.results.search_buf[:], query)
	app.results.search_len = len(query)
	app.results.search_edit = true
	app.results.file_scroll.offset = 60
	filtered := results_filtered_entries(&app)
	testing.expect(t, len(filtered) == 1 && app.results.entries[filtered[0]].is_dir, "filter finds the subfolder")
	if len(filtered) == 0 {return}

	// Mimic clicking the filtered folder row, whose path is owned by entries.
	expected_root := strings.clone(app.results.entries[filtered[0]].path)
	defer delete(expected_root)
	results_set_root(&app, app.results.entries[filtered[0]].path)
	testing.expect(t, app.results.root == expected_root, "navigated into filtered folder")
	testing.expect(t, app.results.search_len == 0 && app.results.search_buf[0] == 0, "folder navigation clears search text")
	testing.expect(t, !app.results.search_edit && app.results.file_scroll.offset == 0, "search focus and scroll reset")
	testing.expect(t, len(results_filtered_entries(&app)) == 1, "new folder's files are visible")
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
	sync.mutex_lock(&global_app_test_mutex)
	defer sync.mutex_unlock(&global_app_test_mutex)
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
	sub_path := app.palette_folder_children[1].description
	testing.expect(t, app.palette_folder_children[1].name == "sub1", "palette target is the subdirectory")
	palette_activate(&app.palette, app.palette.matches[1])
	testing.expect(t, app.results.root == sub_path, "folder palette navigated into the selected subdirectory")

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
	sync.mutex_lock(&global_app_test_mutex)
	defer sync.mutex_unlock(&global_app_test_mutex)
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

@(test)
test_folder_palette_select_after_rescan :: proc(t: ^testing.T) {
	// Regression: selecting a folder after folder_cmds is rebuilt must use the
	// palette-owned description, not an index into the freed list.
	app: App
	results_init(&app)
	palette_init(&app.palette, nil, nil)
	defer {
		results_destroy(&app)
		palette_destroy(&app.palette)
		for p in app.recents {delete(p)}
		delete(app.recents)
		for fc in app.palette_folder_children {
			delete(fc.name)
			delete(fc.description)
		}
		delete(app.palette_folder_children)
	}

	base := fmt.tprintf("/tmp/palantir_rescan_pal_%d", os.get_pid())
	sub1 := fmt.tprintf("%s/sub1", base)
	testing.expect(t, os.make_directory(base) == nil, "create temp dir")
	testing.expect(t, os.make_directory(sub1) == nil, "create temp subdir")
	defer {
		os.remove_all(sub1)
		os.remove_all(base)
	}

	results_set_root(&app, base)
	open_folder_palette(&app)
	testing.expect(t, len(app.palette_folder_children) >= 2, "folder list has parent + subdirs")
	if len(app.palette_folder_children) < 2 {
		return
	}
	path := app.palette_folder_children[1].description
	testing.expect(t, app.palette_folder_children[1].name == "sub1", "palette entry identifies the subdirectory")

	refresh_palette_folders(&app)
	results_handle_folder_select(&app, path)
	testing.expect(t, app.results.root == path, "select after rescan navigated using palette-owned path")
}

@(test)
test_palette_recent_folder_select :: proc(t: ^testing.T) {
	app: App
	results_init(&app)
	defer {
		results_destroy(&app)
		for p in app.recents {delete(p)}
		delete(app.recents)
	}

	base := fmt.tprintf("/tmp/palantir_recent_pal_%d", os.get_pid())
	other := fmt.tprintf("/tmp/palantir_recent_pal_other_%d", os.get_pid())
	testing.expect(t, os.make_directory(base) == nil, "create temp dir")
	testing.expect(t, os.make_directory(other) == nil, "create other dir")
	defer {
		os.remove_all(base)
		os.remove_all(other)
	}

	results_set_root(&app, base)
	results_set_root(&app, other)
	testing.expect(t, len(app.recents) >= 1, "recents recorded")
	if len(app.recents) == 0 {
		return
	}
	path := app.recents[0]
	results_open_folder(&app, path)
	testing.expect(t, app.results.root == path, "recent folder path select navigated")
	testing.expect(t, app.results.show_recents == false, "recents panel closed after select")
}

// --- tiny test helpers ------------------------------------------------------

abs_f64 :: proc(v: f64) -> f64 {
	return v if v >= 0 else -v
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

@(test)
test_refresh_changed_reloads_modified :: proc(t: ^testing.T) {
	// The mtime-based refresh must reload only files that changed on disk,
	// leaving untouched datasets (and their pointers) alone.
	sync.mutex_lock(&global_app_test_mutex)
	defer sync.mutex_unlock(&global_app_test_mutex)
	default_app = {}
	defer default_app = {}
	app := &default_app

	results_init(app)
	defer results_destroy(app)

	tmp := fmt_tmp_path("refresh")
	defer os.remove(tmp)

	err := os.write_entire_file_from_string(tmp, `{"h":[1.0,2.0],"lat":[1.0,2.0],"lon":[3.0,4.0],"u":[5.0,6.0],"v":[7.0,8.0],"w":[9.0,10.0],"x":[1.0,2.0],"y":[10.0,20.0],"z":[2.0,3.0]}`)
	testing.expect(t, err == nil, "failed to write tmp json")
	if err != nil {return}

	ds, ok := load_dataset(tmp)
	testing.expect(t, ok, "failed to load tmp json")
	if !ok {return}
	append(&app.results.datasets, ds)
	app.results.active_ds = 0
	// Live picks across every column slot have not been saved to remembered
	// names yet. Refresh must capture and resolve them all, regardless of plot.
	rs := &app.results
	rs.plot.x_col = results_col_index(ds, "x")
	rs.plot.y_col = results_col_index(ds, "y")
	rs.plot.z_col = results_col_index(ds, "z")
	rs.plot.h_col = results_col_index(ds, "h")
	rs.plot.u_col = results_col_index(ds, "u")
	rs.plot.v_col = results_col_index(ds, "v")
	rs.plot.w_col = results_col_index(ds, "w")
	rs.plot.lat_col = results_col_index(ds, "lat")
	rs.plot.lon_col = results_col_index(ds, "lon")
	before := rawptr(ds)

	// Unchanged file: no reload, dataset kept in place.
	testing.expect(t, !results_refresh_changed(app), "no reload when the file is unchanged")
	testing.expect(t, len(app.results.datasets) == 1 && rawptr(app.results.datasets[0]) == before, "unchanged dataset kept")
	_, _, _, _ = plot_zoom_update(&rs.plot_zoom[PLOT_SCATTER], 0, 10, 0, 10, 0.5, 0.5, 1, false)
	zoom_x_min := rs.plot_zoom[PLOT_SCATTER].x_min
	zoom_x_max := rs.plot_zoom[PLOT_SCATTER].x_max
	zoom_y_min := rs.plot_zoom[PLOT_SCATTER].y_min
	zoom_y_max := rs.plot_zoom[PLOT_SCATTER].y_max

	// Modify the file and give the mtime a chance to advance.
	time.sleep(20 * time.Millisecond)
	werr := os.write_entire_file_from_string(tmp, `{"a":[99.0,99.0],"h":[1.0,2.0],"lat":[1.0,2.0],"lon":[3.0,4.0],"u":[5.0,6.0],"v":[7.0,8.0],"w":[9.0,10.0],"x":[3.0,4.0],"y":[30.0,40.0],"z":[2.0,3.0]}`)
	testing.expect(t, werr == nil, "failed to rewrite tmp json")
	if werr != nil {return}

	testing.expect(t, results_refresh_changed(app), "reload triggered on mtime change")
	testing.expect(t, len(app.results.datasets) == 1 && rawptr(app.results.datasets[0]) != before, "dataset replaced after change")
	if len(app.results.datasets) == 0 {return}
	refreshed := app.results.datasets[0]
	testing.expect(t, rs.plot_zoom[PLOT_SCATTER].preserve_on_base_change, "refresh marks the active plot viewport for preservation")
	_, _, _, _ = plot_zoom_update(&rs.plot_zoom[PLOT_SCATTER], -5, 15, -10, 30, 0.5, 0.5, 0, false)
	testing.expect(t, rs.plot_zoom[PLOT_SCATTER].x_min == zoom_x_min && rs.plot_zoom[PLOT_SCATTER].x_max == zoom_x_max, "plot zoom survives changed data bounds")
	testing.expect(t, rs.plot_zoom[PLOT_SCATTER].y_min == zoom_y_min && rs.plot_zoom[PLOT_SCATTER].y_max == zoom_y_max, "plot vertical zoom survives changed data bounds")
	testing.expect(t, rs.plot.x_col == results_col_index(refreshed, "x"), "X selection survives refresh and column reorder")
	testing.expect(t, rs.plot.y_col == results_col_index(refreshed, "y"), "Y selection survives refresh and column reorder")
	testing.expect(t, rs.plot.z_col == results_col_index(refreshed, "z"), "Z selection survives refresh and column reorder")
	testing.expect(t, rs.plot.h_col == results_col_index(refreshed, "h"), "color/histogram selection survives refresh")
	testing.expect(t, rs.plot.u_col == results_col_index(refreshed, "u"), "U selection survives refresh")
	testing.expect(t, rs.plot.v_col == results_col_index(refreshed, "v"), "V selection survives refresh")
	testing.expect(t, rs.plot.w_col == results_col_index(refreshed, "w"), "W selection survives refresh")
	testing.expect(t, rs.plot.lat_col == results_col_index(refreshed, "lat"), "latitude selection survives refresh")
	testing.expect(t, rs.plot.lon_col == results_col_index(refreshed, "lon"), "longitude selection survives refresh")
	testing.expect(t, rs.remembered.x == "x" && rs.remembered.y == "y" && rs.remembered.z == "z", "coordinate selections are remembered by name")
	testing.expect(t, rs.remembered.h == "h" && rs.remembered.u == "u" && rs.remembered.v == "v" && rs.remembered.w == "w", "color and vector selections are remembered by name")
	testing.expect(t, rs.remembered.lat == "lat" && rs.remembered.lon == "lon", "map selections are remembered by name")
	xc := ds_column(refreshed, "x")
	testing.expect(t, xc != nil && len(xc.floats) == 2 && xc.floats[0] == 3.0, "reloaded dataset has new contents")

	// An active 3D wireframe keeps its fly-camera pose while its source pointer
	// and selected-column indices are updated for the replacement dataset.
	rs.plot.id = PLOT_WIREFRAME3D
	rs.plot.prev_id = PLOT_WIREFRAME3D
	rs.wireframe_src = refreshed
	rs.wireframe_x_col = rs.plot.x_col
	rs.wireframe_y_col = rs.plot.y_col
	rs.wireframe_z_col = rs.plot.z_col
	rs.wireframe_view.fit = false
	rs.wireframe_view.pos = rl.Vector3{21, 22, 23}
	rs.wireframe_view.yaw = 1.25
	rs.wireframe_view.pitch = -0.4
	time.sleep(20 * time.Millisecond)
	werr = os.write_entire_file_from_string(tmp, `{"0":[0.0,0.0],"a":[99.0,99.0],"h":[1.0,2.0],"lat":[1.0,2.0],"lon":[3.0,4.0],"u":[5.0,6.0],"v":[7.0,8.0],"w":[9.0,10.0],"x":[5.0,6.0],"y":[50.0,60.0],"z":[2.0,3.0]}`)
	testing.expect(t, werr == nil, "failed to rewrite wireframe fixture")
	if werr != nil {return}
	testing.expect(t, results_refresh_changed(app), "second refresh reloads the active wireframe source")
	refreshed = active_dataset(rs)
	testing.expect(t, rs.wireframe_view.preserve_camera_once, "wireframe refresh marks its camera to be preserved")
	testing.expect(t, !mesh_view_needs_fit(&rs.wireframe_view), "wireframe refresh suppresses the pending fit")
	testing.expect(t, !rs.wireframe_view.fit, "wireframe refresh does not schedule a camera refit")
	testing.expect(t, rs.wireframe_view.pos.x == 21 && rs.wireframe_view.pos.y == 22 && rs.wireframe_view.pos.z == 23, "wireframe camera position survives refresh")
	testing.expect(t, rs.wireframe_view.yaw == 1.25 && rs.wireframe_view.pitch == -0.4, "wireframe camera orientation survives refresh")
	testing.expect(t, rs.wireframe_src == refreshed && rs.wireframe_x_col == rs.plot.x_col && rs.wireframe_y_col == rs.plot.y_col && rs.wireframe_z_col == rs.plot.z_col, "wireframe cache keys follow the reloaded dataset")

	// No further change: stays put again.
	testing.expect(t, !results_refresh_changed(app), "no reload when unchanged after reload")
}

@(test)
test_mesh_refresh_preserves_field_selections :: proc(t: ^testing.T) {
	tmp := fmt_tmp_path("mesh_refresh")
	defer os.remove(tmp)
	initial := `{"label":["a","b","c"],"x":[0.0,1.0,0.0],"y":[0.0,0.0,1.0],"z":[0.0,0.0,0.0],"vmag":[1.0,2.0,3.0],"triangles":[[0,1,2]]}`
	write_err := os.write_entire_file_from_string(tmp, initial)
	testing.expect(t, write_err == nil, "failed to write initial mesh fixture")
	if write_err != nil {return}

	app: App
	results_init(&app)
	defer results_destroy(&app)
	ds, ds_ok := load_dataset(tmp)
	mesh, mesh_ok := load_mesh_dataset(tmp, "mesh")
	testing.expect(t, ds_ok && mesh_ok, "load mesh fixture as dataset and mesh")
	if !ds_ok || !mesh_ok {return}
	append(&app.results.datasets, ds)
	app.results.active_ds = 0
	app.results.mesh = mesh
	app.results.mesh_path = strings.clone(tmp)
	app.results.plot.id = PLOT_MESH3D
	app.results.plot.x_col = mesh_field_index(mesh, "x")
	app.results.plot.y_col = mesh_field_index(mesh, "y")
	app.results.plot.z_col = mesh_field_index(mesh, "z")
	app.results.plot.h_col = mesh_field_index(mesh, "vmag")
	app.results.mesh_view.fit = false
	app.results.mesh_view.pos = rl.Vector3{31, 32, 33}
	app.results.mesh_view.yaw = 0.75
	app.results.mesh_view.pitch = -0.2

	time.sleep(20 * time.Millisecond)
	changed := `{"a":[4.0,5.0,6.0],"label":["a","b","c"],"x":[0.0,1.0,0.0],"y":[0.0,0.0,1.0],"z":[0.0,0.0,0.0],"vmag":[1.0,2.0,3.0],"triangles":[[0,1,2]]}`
	write_err = os.write_entire_file_from_string(tmp, changed)
	testing.expect(t, write_err == nil, "failed to rewrite mesh fixture")
	if write_err != nil {return}

	testing.expect(t, results_refresh_changed(&app), "mesh refresh triggered on file change")
	testing.expect(t, app.results.remembered.x == "x" && app.results.remembered.y == "y", "mesh coordinate fields remembered by name")
	testing.expect(t, app.results.remembered.z == "z" && app.results.remembered.h == "vmag", "mesh Z/color fields remembered by name")
	refreshed_mesh := results_ensure_mesh(&app, active_dataset(&app.results))
	testing.expect(t, refreshed_mesh != nil, "reloaded mesh available")
	if refreshed_mesh != nil {
		testing.expect(t, app.results.mesh_view.preserve_camera_once, "mesh refresh marks its camera to be preserved")
		testing.expect(t, !mesh_view_needs_fit(&app.results.mesh_view), "mesh refresh suppresses the pending fit")
		testing.expect(t, !app.results.mesh_view.fit, "mesh refresh does not schedule a camera refit")
		testing.expect(t, app.results.mesh_view.pos.x == 31 && app.results.mesh_view.pos.y == 32 && app.results.mesh_view.pos.z == 33, "mesh camera position survives refresh")
		testing.expect(t, app.results.mesh_view.yaw == 0.75 && app.results.mesh_view.pitch == -0.2, "mesh camera orientation survives refresh")
		testing.expect(t, app.results.plot.x_col == mesh_field_index(refreshed_mesh, "x"), "mesh X selection survives reordered fields")
		testing.expect(t, app.results.plot.y_col == mesh_field_index(refreshed_mesh, "y"), "mesh Y selection survives reordered fields")
		testing.expect(t, app.results.plot.z_col == mesh_field_index(refreshed_mesh, "z"), "mesh Z selection survives reordered fields")
		testing.expect(t, app.results.plot.h_col == mesh_field_index(refreshed_mesh, "vmag"), "mesh color selection survives reordered fields")
	}
}

@(test)
test_camera_roll_defaults_and_buttons :: proc(t: ^testing.T) {
	mv := mesh_view_init()
	testing.expect(t, mv.roll == 0, "new 3D cameras have zero roll (level horizon)")
	up := cam_up(&mv)
	testing.expect(t, up == rl.Vector3{0, 0, 1}, "zero roll up vector is plain world-up")

	// Each roll button click rotates by one step.
	mv.roll = 0
	mv.roll += mesh_view_roll_step
	testing.expect(t, abs(f64(mv.roll) - f64(mesh_view_roll_step)) < 1e-9, "roll button step applies")
	mv.roll -= 2 * mesh_view_roll_step
	testing.expect(t, abs(f64(mv.roll) + f64(mesh_view_roll_step)) < 1e-9, "roll button step is reversible")

	// A rolled camera's up vector rotates around the view direction, not the
	// world axes, so the horizon follows the view.
	mv.roll = mesh_view_roll_step
	up = cam_up(&mv)
	testing.expect(t, up.z > 0.9, "a small roll keeps the up vector mostly vertical")
	testing.expect(t, abs(v3_len(up) - 1) < 1e-5, "rolled up vector stays unit length")

	// Both reset paths restore the zero-roll default.
	view_reset_default(&mv, [3]f64{-1, -1, -1}, [3]f64{1, 1, 1})
	testing.expect(t, mv.roll == 0, "reset view clears roll")
	mv.roll = 1.0
	view_fit_bounds(&mv, [3]f64{-1, -1, -1}, [3]f64{1, 1, 1})
	testing.expect(t, mv.roll == 0, "camera fit clears roll")
}

@(test)
test_remembered_columns :: proc(t: ^testing.T) {
	// The remembered column names (persisted in settings) must resolve into
	// indices for the active dataset and re-sync from live selections without
	// wiping slots whose selection doesn't resolve.
	sync.mutex_lock(&global_app_test_mutex)
	defer sync.mutex_unlock(&global_app_test_mutex)
	default_app = {}
	defer default_app = {}
	app := &default_app

	results_init(app)
	defer results_destroy(app)

	ds := new(Dataset)
	ds.name = strings.clone("rem")
	ds.n_rows = 3
	ds.columns = make([]Column, 3)
	ds.columns[0].name = strings.clone("alpha")
	ds.columns[1].name = strings.clone("Beta")
	ds.columns[2].name = strings.clone("gamma")
	append(&app.results.datasets, ds)
	app.results.active_ds = 0

	rs := &app.results
	rs.remembered.x = strings.clone("Beta")
	rs.remembered.h = strings.clone("gamma")
	rs.remembered.lat = strings.clone("missing")

	results_apply_remembered(app)
	testing.expect(t, rs.plot.x_col == 1, "remembered name resolved case-insensitively")
	testing.expect(t, rs.plot.h_col == 2, "remembered h resolved")
	testing.expect(t, rs.plot.lat_col == -1, "missing column -> -1 (auto)")

	// Syncing records the current selections by name and preserves a slot
	// whose selection can't be resolved (so a save never wipes a good one).
	rs.plot.v_col = 0
	results_sync_remembered(app)
	testing.expect(t, rs.remembered.v == "alpha", "current selection synced to name")
	testing.expect(t, rs.remembered.lat == "missing", "unresolvable selection keeps prior name")
	testing.expect(t, rs.remembered.x == "Beta", "exact column name stored")
}

// Settings must live in the platform config directory (e.g. ~/.config/palantir
// on Linux), never in the working directory, and that directory must be created
// on demand and writable.
@(test)
test_settings_path_platform_config :: proc(t: ^testing.T) {
	when ODIN_OS != .JS {
		path := settings_path()
		defer delete(path)
		testing.expect(t, path != "", "expected a settings path on native")
		if path == "" {return}

		cwd, err := os.get_working_directory(context.allocator)
		testing.expect(t, err == nil, "could not get working directory")
		if err != nil {return}
		defer delete(cwd)

		rel, rerr := filepath.rel(cwd, path)
		testing.expect(t, rerr == nil, "could not compute path relative to cwd")
		if rerr != nil {return}
		defer delete(rel)
		testing.expect(t, strings.has_prefix(rel, ".."), "settings must be outside the working directory")

		// The config directory is created on demand and writable.
		probe, jerr := filepath.join([]string{filepath.dir(path), "palantir_write_probe.tmp"}, context.allocator)
		testing.expect(t, jerr == nil, "could not build probe path")
		if jerr != nil {return}
		defer delete(probe)
		werr := os.write_entire_file_from_string(probe, "probe")
		testing.expect(t, werr == nil, "config directory must be writable")
		if werr == nil {
			os.remove(probe)
		}
	}
}