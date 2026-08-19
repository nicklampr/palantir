package palantir

// Results explorer view: browse a folder for .csv/.json files, multi-select
// them, choose one of the available plots (Map / Line / Histogram / 2D
// histogram), and inspect the raw data in a virtualized table that only
// renders the rows that are actually visible.

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:sort"
import "core:strings"
import rl "vendor:raylib"

RECENT_CMD_BASE :: 2000
RECENT_MAX :: 12
MAX_PLOT_POINTS :: 20000
RAW_COL_MIN_W :: 90

PLOT_MAP :: 0
PLOT_LINE :: 1
PLOT_HIST :: 2
PLOT_HIST2D :: 3

File_Entry :: struct {
	name:   string,
	path:   string,
	is_dir: bool,
	size:   i64,
}

Results_Plot :: struct {
	id:       int, // PLOT_MAP / PLOT_LINE / PLOT_HIST / PLOT_HIST2D
	// Column selections (index into the active dataset's columns; -1 = auto).
	x_col:   int,
	y_col:   int,
	h_col:   int,
	lat_col: int,
	lon_col: int,
	// Dropdown popup state.
	x_open, y_open, h_open, lat_open, lon_open: bool,
	// Per-dropdown popup scroll offset (index into the column list).
	x_scroll, y_scroll, h_scroll, lat_scroll, lon_scroll: int,
	bins: int, // histogram bin count (0 = auto)
}

Results_State :: struct {
	root:          string,
	entries:       []File_Entry,
	dir_scroll:    Scroll_State,
	file_scroll:   Scroll_State,
	path_buf:      [512]u8,
	path_len:      int,
	path_edit:     bool,
	selected:      [dynamic]int,
	file_cursor:   int, // keyboard cursor into the file list (0 = ".." row when present)
	datasets:      [dynamic]^Dataset,
	active_ds:     int,
	raw_scroll:    Scroll_State,
	raw_col_scroll: f32,
	raw_widths:    [dynamic]f32,
	show_recents:  bool,
	plot:          Results_Plot,
	map_view:      Map_View,
	map_bg:        Map_Background,
	map_bg_init:   bool,
	msg:           string,
}

// --- state lifecycle ---------------------------------------------------------

results_init :: proc(app: ^App) {
	rs := &app.results
	rs.active_ds = -1
	rs.file_cursor = 0
	rs.plot = Results_Plot {
		id = PLOT_MAP,
		x_col = -1,
		y_col = -1,
		h_col = -1,
		lat_col = -1,
		lon_col = -1,
	}
	rs.map_view = Map_View{center_lon = 0, center_lat = 25, lon_span = 360}
}

results_destroy :: proc(app: ^App) {
	rs := &app.results
	for e in rs.entries {
		delete(e.name)
		delete(e.path)
	}
	delete(rs.entries)
	delete(rs.selected)
	for ds in rs.datasets {
		if ds != nil {
			dataset_destroy(ds)
			free(ds)
		}
	}
	delete(rs.datasets)
	delete(rs.raw_widths)
	if rs.root != "" {
		delete(rs.root)
	}
	if rs.msg != "" {
		delete(rs.msg)
	}
	destroy_map_background(&rs.map_bg)
}

// --- directory browsing ------------------------------------------------------

results_scan :: proc(app: ^App) {
	rs := &app.results
	for e in rs.entries {
		delete(e.name)
		delete(e.path)
	}
	delete(rs.entries)
	rs.entries = nil
	clear(&rs.selected)

	entries := make([dynamic]File_Entry, 0, 128, context.allocator)
	fi, err := os.read_directory_by_path(rs.root, -1, context.allocator)
	if err != nil {
		results_msg(app, fmt.aprintf("Cannot read folder: %v", err))
		delete(entries)
		return
	}
	defer os.file_info_slice_delete(fi, context.allocator)

	for info in fi {
		if info.name == "." || info.name == ".." {
			continue
		}
		if info.type == .Directory {
			append(&entries, File_Entry {
				name = strings.clone(info.name),
				path = strings.clone(info.fullpath),
				is_dir = true,
			})
		} else {
			ext := file_extension(info.name)
			if ext == ".csv" || ext == ".json" {
				append(&entries, File_Entry {
					name = strings.clone(info.name),
					path = strings.clone(info.fullpath),
					is_dir = false,
					size = info.size,
				})
			}
		}
	}
	sort.quick_sort_proc(entries[:], proc(a, b: File_Entry) -> int {
		if a.is_dir != b.is_dir {
			return -1 if a.is_dir else 1
		}
		return strings.compare(a.name, b.name)
	})

	rs.entries = entries[:] // dynamic backing is now owned by rs.entries
	rs.file_cursor = 0
	results_clear_msg(app)
}

results_set_root :: proc(app: ^App, path: string) {
	rs := &app.results
	if rs.root != "" {
		delete(rs.root)
	}
	rs.root = strings.clone(path)
	// Keep the path input box in sync with the current folder.
	rs.path_len = min(len(path), len(rs.path_buf) - 1)
	for i in 0 ..< rs.path_len {
		rs.path_buf[i] = path[i]
	}
	rs.path_buf[rs.path_len] = 0
	results_scan(app)
}

// Opens whatever `path` points to: a folder becomes the browse root, a .csv /
// .json file is opened directly (its folder is browsed and the file selected),
// and anything else gets a friendly message instead of an error.
results_open_path :: proc(app: ^App, path: string) {
	if !os.exists(path) {
		results_msg(app, fmt.aprintf("Path does not exist: %s", path))
		return
	}
	if os.is_directory(path) {
		results_set_root(app, path)
		return
	}
	ext := file_extension(path)
	if ext != ".csv" && ext != ".json" {
		label := ext if ext != "" else "no file extension"
		results_msg(app, fmt.aprintf("Not a result file (%s): %s", label, file_base_name(path)))
		return
	}

	dir := filepath.dir(path)
	if len(dir) == 0 {
		dir = "."
	}
	results_set_root(app, dir)
	rs := &app.results
	found := -1
	for e, i in rs.entries {
		if !e.is_dir && e.path == path {
			found = i
			break
		}
	}
	if found >= 0 {
		results_select_only(app, found)
	} else {
		// File is valid but not in the listing (e.g. symlink edge case).
		if ds, ok := load_dataset(path); ok {
			append(&rs.datasets, ds)
			rs.active_ds = len(rs.datasets) - 1
			results_add_recent(app, path)
			results_compute_raw_widths(app)
		} else {
			results_msg(app, fmt.aprintf("Failed to load %s", file_base_name(path)))
		}
	}
	rs.show_recents = false
}

results_go_up :: proc(app: ^App) {
	rs := &app.results
	if len(rs.root) == 0 {
		return
	}
	parent := filepath.dir(rs.root)
	if parent == rs.root {
		return
	}
	results_set_root(app, parent)
}

// Auto-completes the path input on Tab. Completes the last path segment against
// the current folder (when no '/' is typed) or the directory named by the text
// up to the last '/'. A single match is completed in full (with a trailing '/'
// for directories); multiple matches extend to their longest common prefix.
results_complete_path :: proc(app: ^App) {
	rs := &app.results
	text := string(rs.path_buf[:rs.path_len])
	if len(text) == 0 {
		return
	}
	slash := strings.last_index_byte(text, '/')
	dir_part, base := "", text
	if slash >= 0 {
		dir_part = text[:slash + 1]
		base = text[slash + 1:]
	}

	matches := make([dynamic]string, 0, 16, context.temp_allocator)
	dirs := make([dynamic]bool, 0, 16, context.temp_allocator)
	defer delete(matches)
	defer delete(dirs)

	if slash < 0 {
		// Candidates come from the currently browsed folder.
		for e in rs.entries {
			if strings.has_prefix(e.name, base) {
				append(&matches, e.name)
				append(&dirs, e.is_dir)
			}
		}
	} else {
		full_dir := dir_part
		if !filepath.is_abs(full_dir) {
			full_dir, _ = filepath.join({rs.root, dir_part})
		}
		fi, err := os.read_directory_by_path(full_dir, -1, context.temp_allocator)
		if err != nil {
			return
		}
		defer os.file_info_slice_delete(fi, context.temp_allocator)
		for info in fi {
			if info.name == "." || info.name == ".." {
				continue
			}
			if strings.has_prefix(info.name, base) {
				append(&matches, info.name)
				append(&dirs, info.type == .Directory)
			}
		}
	}
	if len(matches) == 0 {
		return
	}

	completed := matches[0]
	if len(matches) == 1 {
		if dirs[0] {
			completed = strings.concatenate({completed, "/"}, context.temp_allocator)
		}
	} else {
		// Longest common prefix of all matches.
		common := matches[0]
		for m in matches[1:] {
			for len(common) > 0 && !strings.has_prefix(m, common) {
				common = common[:len(common) - 1]
			}
		}
		completed = common
	}

	new_text := strings.concatenate({dir_part, completed}, context.temp_allocator)
	n := min(len(new_text), len(rs.path_buf) - 1)
	for i in 0 ..< n {
		rs.path_buf[i] = new_text[i]
	}
	rs.path_buf[n] = 0
	rs.path_len = n
}

results_msg :: proc(app: ^App, s: string) {
	if app.results.msg != "" {
		delete(app.results.msg)
	}
	app.results.msg = s
}

results_clear_msg :: proc(app: ^App) {
	if app.results.msg != "" {
		delete(app.results.msg)
	}
	app.results.msg = ""
}

// --- selection / dataset sync -----------------------------------------------

results_toggle_select :: proc(app: ^App, entry_idx: int) {
	rs := &app.results
	if entry_idx < 0 || entry_idx >= len(rs.entries) {
		return
	}
	e := rs.entries[entry_idx]
	if e.is_dir {
		return
	}
	found := -1
	for s, i in rs.selected {
		if s == entry_idx {
			found = i
			break
		}
	}
	if found >= 0 {
		ordered_remove(&rs.selected, found)
	} else {
		append(&rs.selected, entry_idx)
	}
	results_sync_datasets(app)
}

results_select_only :: proc(app: ^App, entry_idx: int) {
	clear(&app.results.selected)
	append(&app.results.selected, entry_idx)
	results_sync_datasets(app)
}

results_sync_datasets :: proc(app: ^App) {
	rs := &app.results

	// Build the set of wanted paths.
	wanted := make([dynamic]string, 0, len(rs.selected), context.temp_allocator)
	for idx in rs.selected {
		if idx >= 0 && idx < len(rs.entries) {
			append(&wanted, rs.entries[idx].path)
		}
	}

	// Drop datasets no longer wanted.
	keep := 0
	for i in 0 ..< len(rs.datasets) {
		ds := rs.datasets[i]
		keep_it := false
		for w in wanted {
			if ds != nil && ds.path == w {
				keep_it = true
				break
			}
		}
		if keep_it {
			rs.datasets[keep] = ds
			keep += 1
		} else if ds != nil {
			dataset_destroy(ds)
			free(ds)
		}
	}
	resize(&rs.datasets, keep)

	// Load missing datasets.
	for w in wanted {
		exists := false
		for ds in rs.datasets {
			if ds != nil && ds.path == w {
				exists = true
				break
			}
		}
		if exists {
			continue
		}
		if ds, ok := load_dataset(w); ok {
			append(&rs.datasets, ds)
			results_add_recent(app, w)
		} else {
			results_msg(app, fmt.aprintf("Failed to load %s", file_base_name(w)))
		}
	}

	if len(rs.datasets) == 0 {
		rs.active_ds = -1
	} else if rs.active_ds < 0 || rs.active_ds >= len(rs.datasets) {
		rs.active_ds = len(rs.datasets) - 1
	}
	results_compute_raw_widths(app)
}

// --- recents -----------------------------------------------------------------

results_add_recent :: proc(app: ^App, path: string) {
	// Dedup: collect the surviving entries (everything except `path`).
	survivors := make([dynamic]string, 0, len(app.recents), context.temp_allocator)
	for p in app.recents {
		if p != path {
			append(&survivors, p)
		} else {
			delete(p)
		}
	}
	// The old backing array is freed; the surviving strings are moved on.
	delete(app.recents)

	new_len := min(len(survivors) + 1, RECENT_MAX)
	out := make([]string, new_len, context.allocator)
	out[0] = strings.clone(path)
	n := 1
	for s in survivors {
		if n >= new_len {
			delete(s)
			continue
		}
		out[n] = s
		n += 1
	}
	app.recents = out
	app.recents_dirty = true
	save_settings(app)
}

results_open_recent :: proc(app: ^App, idx: int) {
	if idx < 0 || idx >= len(app.recents) {
		return
	}
	path := app.recents[idx]
	if !os.exists(path) {
		results_msg(app, "File no longer exists")
		return
	}
	// Switch the browser to the file's folder and select it.
	dir := filepath.dir(path)
	results_set_root(app, dir)
	rs := &app.results
	for e, i in rs.entries {
		if !e.is_dir && e.path == path {
			results_select_only(app, i)
			break
		}
	}
	rs.active_ds = len(rs.datasets) - 1 if len(rs.datasets) > 0 else -1
	rs.show_recents = false
	results_compute_raw_widths(app)
}

results_clear_recents :: proc(app: ^App) {
	for p in app.recents {
		delete(p)
	}
	delete(app.recents)
	app.recents = nil
	app.recents_dirty = true
	save_settings(app)
}

// --- commands ----------------------------------------------------------------

open_results_folder :: proc(app: ^App) {
	cwd, _ := os.get_working_directory(context.temp_allocator)
	results_set_root(app, cwd)
	app.results.show_recents = false
	app.view = .view_results
	app.results.map_bg_init = false
}

open_recents_view :: proc(app: ^App) {
	app.results.show_recents = true
	app.view = .view_results
}

// --- palette recents submenu -------------------------------------------------

refresh_palette_recents :: proc(app: ^App) {
	clear(&app.palette_recent_children)
	for p, i in app.recents {
		append(&app.palette_recent_children, Palette_Command {
			name = file_base_name(p),
			description = p,
			user_data = rawptr(uintptr(RECENT_CMD_BASE + i)),
		})
	}
	clear(&app.palette_root)
	for cmd in gui_commands {
		c := cmd
		if GuiCommand(uintptr(c.user_data)) == .recent_files {
			c.children = app.palette_recent_children[:]
		}
		append(&app.palette_root, c)
	}
	app.palette.root_commands = app.palette_root[:]
	if len(app.palette.layer_stack) == 0 {
		app.palette.commands = app.palette.root_commands
	}
}

// --- column helpers ----------------------------------------------------------

ds_column_names :: proc(ds: ^Dataset) -> []string {
	if ds == nil {
		return nil
	}
	names := make([]string, len(ds.columns), context.temp_allocator)
	for c, i in ds.columns {
		names[i] = c.name
	}
	return names
}

// Name of the column selected for `idx` in the active dataset ("" if auto/none).
results_col_name :: proc(app: ^App, idx: int) -> string {
	ds := active_dataset(&app.results)
	if ds == nil || idx < 0 || idx >= len(ds.columns) {
		return ""
	}
	return ds.columns[idx].name
}

active_dataset :: proc(rs: ^Results_State) -> ^Dataset {
	if rs.active_ds >= 0 && rs.active_ds < len(rs.datasets) {
		return rs.datasets[rs.active_ds]
	}
	return nil
}

// --- main view ---------------------------------------------------------------

draw_results_view :: proc(app: ^App) {
	t := app.themes[app.theme_index]
	s := app.palette.style
	sc := app.ui_scale
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	rs := &app.results

	// --- top bar: path input + actions -------------------------------------
	// Content must start below the clickable tab bar (drawn on top at the very
	// top of the window).
	top := view_tab_height * sc + 6 * sc
	bar_h := 44 * sc
	path_rect := rl.Rectangle{12 * sc, top + 8 * sc, sw * 0.55, 30 * sc}
	up_rect := rl.Rectangle{path_rect.x + path_rect.width + 6 * sc, top + 8 * sc, 64 * sc, 30 * sc}
	recents_rect := rl.Rectangle{up_rect.x + up_rect.width + 6 * sc, top + 8 * sc, 110 * sc, 30 * sc}
	refresh_rect := rl.Rectangle{recents_rect.x + recents_rect.width + 6 * sc, top + 8 * sc, 90 * sc, 30 * sc}

	if draw_text_input(
		path_rect,
		rs.path_buf[:],
		&rs.path_len,
		&rs.path_edit,
		t,
		sc,
	) {
		path := strings.trim_space(string(rs.path_buf[:rs.path_len]))
		if len(path) > 0 {
			results_open_path(app, path)
		}
	}
	if rs.path_edit && rl.IsKeyPressed(.TAB) {
		results_complete_path(app)
	}
	if draw_button(up_rect, "Up", t, sc) {
		results_go_up(app)
	}
	if draw_button(recents_rect, "Recents", t, sc) {
		rs.show_recents = true
	}
	if draw_button(refresh_rect, "Refresh", t, sc) {
		results_scan(app)
	}

	if rs.root != "" {
		root_c := strings.clone_to_cstring(rs.root, context.temp_allocator)
		draw_text(root_c, c.int(12 * sc), c.int(top + bar_h + 2 * sc), i32(12 * sc), rl.Fade(t.text, 0.6))
	}
	if rs.msg != "" {
		msg_c := strings.clone_to_cstring(rs.msg, context.temp_allocator)
		draw_text(msg_c, c.int(sw * 0.55 + 12 * sc), c.int(top + bar_h + 2 * sc), i32(12 * sc), t.axis_z)
	}

	// --- layout -------------------------------------------------------------
	bottom_h := 210 * sc
	body_top := top + bar_h + 12 * sc
	body_bottom := sh - bottom_h - 4 * sc
	left_w := 330 * sc
	left := rl.Rectangle{8 * sc, body_top, left_w, body_bottom - body_top}
	right := rl.Rectangle {
		left.x + left.width + 8 * sc,
		body_top,
		sw - (left.x + left.width + 8 * sc) - 8 * sc,
		body_bottom - body_top,
	}
	raw := rl.Rectangle{8 * sc, body_bottom + 4 * sc, sw - 16 * sc, sh - body_bottom - 8 * sc}

	// --- left panel ----------------------------------------------------------
	if rs.show_recents {
		draw_recents_panel(app, left)
	} else {
		draw_file_browser(app, left)
	}

	// --- right panel: plot ---------------------------------------------------
	draw_plot_panel(app, right)

	// --- bottom panel: raw data ---------------------------------------------
	draw_raw_table(app, raw)
}

draw_file_browser :: proc(app: ^App, panel: rl.Rectangle) {
	t := app.themes[app.theme_index]
	s := app.palette.style
	sc := app.ui_scale
	rs := &app.results

	rl.DrawRectangleRec(panel, s.panel)
	rl.DrawRectangleLinesEx(panel, 1, s.border)

	title_h := 26 * sc
	draw_text("Files", c.int(panel.x + 8 * sc), c.int(panel.y + 6 * sc), i32(15 * sc), t.text)

	sel_count := fmt.ctprintf("%d selected", len(rs.selected))
	draw_text(
		sel_count,
		c.int(panel.x + panel.width - f32(measure_text(sel_count, i32(12 * sc))) - 8 * sc),
		c.int(panel.y + 8 * sc),
		i32(12 * sc),
		rl.Fade(t.text, 0.6),
	)

	viewport := rl.Rectangle{panel.x, panel.y + title_h, panel.width, panel.height - title_h}

	row_h := 26 * sc
	pitch := row_h + 2 * sc
	has_parent := len(rs.root) > 0 && filepath.dir(rs.root) != rs.root
	total_rows := len(rs.entries) + 1 if has_parent else len(rs.entries)
	if total_rows > 0 {
		rs.file_cursor = clamp(rs.file_cursor, 0, total_rows - 1)
	}

	// Keyboard navigation (gated so it never fights the palette, the path
	// input, or an open dropdown).
	if !app.palette.open && !rs.path_edit && !results_any_dropdown_open(rs) {
		if total_rows > 0 && rl.IsKeyPressed(.DOWN) {
			rs.file_cursor = min(rs.file_cursor + 1, total_rows - 1)
		}
		if total_rows > 0 && rl.IsKeyPressed(.UP) {
			rs.file_cursor = max(rs.file_cursor - 1, 0)
		}
		if rl.IsKeyPressed(.LEFT) {
			results_go_up(app)
		}
		if rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressed(.ENTER) {
			if rs.file_cursor == 0 && has_parent {
				results_go_up(app)
			} else {
				entry_idx := rs.file_cursor - 1 if has_parent else rs.file_cursor
				if entry_idx >= 0 && entry_idx < len(rs.entries) {
					if rs.entries[entry_idx].is_dir {
						results_set_root(app, rs.entries[entry_idx].path)
					} else {
						results_select_only(app, entry_idx)
					}
				}
			}
		}
		// Keep the cursor row visible.
		if total_rows > 0 {
			row_y := viewport.y + SCROLLBAR_PAD * sc - rs.file_scroll.offset + f32(rs.file_cursor) * pitch
			if row_y < viewport.y {
				rs.file_scroll.offset = SCROLLBAR_PAD * sc + f32(rs.file_cursor) * pitch
			}
			if row_y + row_h > viewport.y + viewport.height {
				rs.file_scroll.offset = SCROLLBAR_PAD * sc + f32(rs.file_cursor) * pitch + row_h - viewport.height
			}
			max_off := max(rs.file_scroll.content - viewport.height, 0)
			rs.file_scroll.offset = clamp(rs.file_scroll.offset, 0, max_off)
		}
	}

	rl.BeginScissorMode(
		c.int(viewport.x),
		c.int(viewport.y),
		c.int(viewport.width),
		c.int(viewport.height),
	)
	u := ui_scroll_begin(&rs.file_scroll, viewport, sc, !app.palette.open)

	if has_parent {
		row := ui_alloc(&u, row_h, 2 * sc)
		draw_row(app, row, "..", true, false, t, sc)
	}

	for e, i in rs.entries {
		row := ui_alloc(&u, row_h, 2 * sc)
		selected := false
		for s2 in rs.selected {
			if s2 == i {
				selected = true
				break
			}
		}
		draw_row(app, row, e.name, e.is_dir, selected, t, sc)
	}

	// Cursor highlight (keyboard navigation).
	if total_rows > 0 {
		cursor_y := viewport.y + SCROLLBAR_PAD * sc - rs.file_scroll.offset + f32(rs.file_cursor) * pitch
		rl.DrawRectangleRec(
			rl.Rectangle{viewport.x + 2 * sc, cursor_y, viewport.width - 4 * sc, row_h},
			rl.Fade(t.axis_x, 0.15),
		)
	}
	ui_scroll_end(&u, &rs.file_scroll, viewport, t, sc)

	// row interaction
	mouse := rl.GetMousePosition()
	if !app.palette.open && rl.IsMouseButtonReleased(.LEFT) && rl.CheckCollisionPointRec(mouse, viewport) {
		row_top := viewport.y + SCROLLBAR_PAD * sc - rs.file_scroll.offset
		row0 := int((mouse.y - row_top) / pitch)
		if row0 < 0 {
			return
		}
		rs.file_cursor = row0
		if has_parent {
			if row0 == 0 {
				results_go_up(app)
				return
			}
			row0 -= 1
		}
		if row0 >= 0 && row0 < len(rs.entries) {
			ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
			if rs.entries[row0].is_dir {
				results_set_root(app, rs.entries[row0].path)
			} else if ctrl {
				results_toggle_select(app, row0)
			} else {
				results_select_only(app, row0)
			}
		}
	}
}

draw_row :: proc(
	app: ^App,
	row: rl.Rectangle,
	label: string,
	is_dir, selected: bool,
	theme: Theme,
	sc: f32,
) {
	if selected {
		rl.DrawRectangleRec(row, rl.Fade(theme.axis_x, 0.25))
	}
	name := label
	if is_dir {
		name = strings.concatenate({"[D] ", label}, context.temp_allocator)
	} else if selected {
		name = strings.concatenate({"[x] ", label}, context.temp_allocator)
	} else {
		name = strings.concatenate({"[ ] ", label}, context.temp_allocator)
	}
	name_c := strings.clone_to_cstring(name, context.temp_allocator)
	col := theme.axis_y if is_dir else theme.text
	draw_text(name_c, c.int(row.x + 8 * sc), c.int(row.y + 5 * sc), i32(13 * sc), col)
}

draw_recents_panel :: proc(app: ^App, panel: rl.Rectangle) {
	t := app.themes[app.theme_index]
	s := app.palette.style
	sc := app.ui_scale
	rs := &app.results

	rl.DrawRectangleRec(panel, s.panel)
	rl.DrawRectangleLinesEx(panel, 1, s.border)

	title_h := 26 * sc
	draw_text("Recent files", c.int(panel.x + 8 * sc), c.int(panel.y + 6 * sc), i32(15 * sc), t.text)

	clear_rect := rl.Rectangle{panel.x + panel.width - 92 * sc, panel.y + 4 * sc, 84 * sc, 22 * sc}
	if draw_button(clear_rect, "Clear", t, sc) {
		results_clear_recents(app)
	}

	back_rect := rl.Rectangle{panel.x + 8 * sc, panel.y + title_h + 4 * sc, 120 * sc, 24 * sc}
	if draw_button(back_rect, "< Browse", t, sc) {
		rs.show_recents = false
	}

	viewport := rl.Rectangle{panel.x, panel.y + title_h + 34 * sc, panel.width, panel.height - title_h - 34 * sc}
	rl.BeginScissorMode(
		c.int(viewport.x),
		c.int(viewport.y),
		c.int(viewport.width),
		c.int(viewport.height),
	)
	u := ui_scroll_begin(&rs.dir_scroll, viewport, sc, !app.palette.open)

	row_h := 30 * sc
	if len(app.recents) == 0 {
		row := ui_alloc(&u, row_h)
		draw_text("No recent files yet", c.int(row.x + 8 * sc), c.int(row.y + 6 * sc), i32(13 * sc), rl.Fade(t.text, 0.5))
	}
	for p, i in app.recents {
		row := ui_alloc(&u, row_h, 2 * sc)
		name_c := strings.clone_to_cstring(file_base_name(p), context.temp_allocator)
		draw_text(name_c, c.int(row.x + 8 * sc), c.int(row.y + 3 * sc), i32(13 * sc), t.text)
		path_c := strings.clone_to_cstring(p, context.temp_allocator)
		draw_text(path_c, c.int(row.x + 8 * sc), c.int(row.y + 16 * sc), i32(11 * sc), rl.Fade(t.text, 0.5))
	}
	ui_scroll_end(&u, &rs.dir_scroll, viewport, t, sc)

	mouse := rl.GetMousePosition()
	if !app.palette.open && rl.IsMouseButtonReleased(.LEFT) && rl.CheckCollisionPointRec(mouse, viewport) {
		idx := int((mouse.y - (viewport.y + SCROLLBAR_PAD * sc) + rs.dir_scroll.offset) / row_h)
		if idx >= 0 && idx < len(app.recents) {
			results_open_recent(app, idx)
		}
	}
}

// --- plot panel --------------------------------------------------------------

draw_plot_panel :: proc(app: ^App, panel: rl.Rectangle) {
	t := app.themes[app.theme_index]
	s := app.palette.style
	sc := app.ui_scale
	rs := &app.results

	// plot tabs
	tab_h := 30 * sc
	tabs := [4]cstring{"Map", "Line", "Histogram", "2D"}
	tab_w := (panel.width - 3 * 6 * sc) / 4

	// column pickers
	cfg_h := 34 * sc
	cfg_rect := rl.Rectangle{panel.x, panel.y + tab_h + 6 * sc, panel.width, cfg_h}

	plot_rect := rl.Rectangle {
		panel.x,
		panel.y + tab_h + cfg_h + 12 * sc,
		panel.width,
		panel.height - tab_h - cfg_h - 12 * sc,
	}

	fs := i32(12 * sc)
	if len(rs.datasets) == 0 {
		hint := strings.clone_to_cstring("Select one or more .csv / .json files to plot", context.temp_allocator)
		rl.DrawRectangleRec(plot_rect, t.bg)
		rl.DrawRectangleLinesEx(plot_rect, 1, t.border)
		draw_text(
			hint,
			c.int(plot_rect.x + 12 * sc),
			c.int(plot_rect.y + 12 * sc),
			fs,
			rl.Fade(t.text, 0.7),
		)
	} else {
		// Draw the plot first so the config row (with its popups) stays on top.
		switch rs.plot.id {
		case PLOT_MAP:
			if !rs.map_bg_init {
				rs.map_bg_init = load_map_background(&rs.map_bg)
			}
			if rs.map_view.lon_span == 0 {
				rs.map_view = Map_View{center_lon = 0, center_lat = 25, lon_span = 360}
			}
			routes := build_map_routes(app)
			if len(routes) == 0 {
				hint := strings.clone_to_cstring("No lat/lon columns in the selected files", context.temp_allocator)
				rl.DrawRectangleRec(plot_rect, t.bg)
				rl.DrawRectangleLinesEx(plot_rect, 1, t.border)
				draw_text(hint, c.int(plot_rect.x + 12 * sc), c.int(plot_rect.y + 12 * sc), fs, rl.Fade(t.text, 0.7))
			} else {
				plot_earth_map(
					app,
					routes,
					&rs.map_view,
					&rs.map_bg,
					"Track map",
					plot_rect,
					t,
					fs,
					sc,
					!app.palette.open,
				)
			}

		case PLOT_LINE:
			x_name := results_col_name(app, rs.plot.x_col)
			y_name := results_col_name(app, rs.plot.y_col)
			if x_name == "" || y_name == "" {
				hint := strings.clone_to_cstring("Pick x and y columns", context.temp_allocator)
				rl.DrawRectangleRec(plot_rect, t.bg)
				rl.DrawRectangleLinesEx(plot_rect, 1, t.border)
				draw_text(hint, c.int(plot_rect.x + 12 * sc), c.int(plot_rect.y + 12 * sc), fs, rl.Fade(t.text, 0.7))
			} else {
				series := build_line_series(app, x_name, y_name)
				if len(series) == 0 {
					hint := strings.clone_to_cstring("No data", context.temp_allocator)
					rl.DrawRectangleRec(plot_rect, t.bg)
					rl.DrawRectangleLinesEx(plot_rect, 1, t.border)
					draw_text(hint, c.int(plot_rect.x + 12 * sc), c.int(plot_rect.y + 12 * sc), fs, rl.Fade(t.text, 0.7))
				} else {
					x_label := x_name
					xc := active_dataset(rs)
					if xc != nil {
						cx_col := ds_column(xc, x_name)
						if is_time_column(cx_col) {
							x_label = "time (s)"
						}
					}
					plot_series(app, series, "Line plot", x_label, y_name, plot_rect, t, fs, sc)
				}
			}

		case PLOT_HIST:
			ds := active_dataset(rs)
			if ds != nil {
				h_name := results_col_name(app, rs.plot.h_col)
				if h_name == "" {
					hint := strings.clone_to_cstring("Pick a column", context.temp_allocator)
					rl.DrawRectangleRec(plot_rect, t.bg)
					rl.DrawRectangleLinesEx(plot_rect, 1, t.border)
					draw_text(hint, c.int(plot_rect.x + 12 * sc), c.int(plot_rect.y + 12 * sc), fs, rl.Fade(t.text, 0.7))
				} else {
					col := ds_column(ds, h_name)
					values := ds_hist_values(col, 100000)
					plot_histogram(app, values, fmt.tprintf("Histogram: %s (%s)", h_name, ds.name), h_name, "count", rs.plot.bins, plot_rect, t, fs, sc, &rs.plot.bins)
				}
			}

		case PLOT_HIST2D:
			ds := active_dataset(rs)
			if ds != nil {
				x_name := results_col_name(app, rs.plot.x_col)
				y_name := results_col_name(app, rs.plot.y_col)
				if x_name == "" || y_name == "" {
					hint := strings.clone_to_cstring("Pick x and y columns", context.temp_allocator)
					rl.DrawRectangleRec(plot_rect, t.bg)
					rl.DrawRectangleLinesEx(plot_rect, 1, t.border)
					draw_text(hint, c.int(plot_rect.x + 12 * sc), c.int(plot_rect.y + 12 * sc), fs, rl.Fade(t.text, 0.7))
				} else {
					xc := ds_column(ds, x_name)
					yc := ds_column(ds, y_name)
					pts := ds_series_xy(ds, xc, yc, 100000)
					if len(pts) == 0 {
						hint := strings.clone_to_cstring("No data", context.temp_allocator)
						rl.DrawRectangleRec(plot_rect, t.bg)
						rl.DrawRectangleLinesEx(plot_rect, 1, t.border)
						draw_text(hint, c.int(plot_rect.x + 12 * sc), c.int(plot_rect.y + 12 * sc), fs, rl.Fade(t.text, 0.7))
					} else {
						plot_histogram_2d(app, pts, "2D histogram", x_name, y_name, 0, 0, plot_rect, t, fs, sc)
					}
				}
			}
	}
	}

	// tabs + column config drawn last so their popups render above the plot.
	cx := panel.x
	for label, i in tabs {
		rect := rl.Rectangle{cx, panel.y, tab_w, tab_h}
		active := rs.plot.id == i
		if draw_tab_button(rect, label, active, t, sc) {
			rs.plot.id = i
		}
		cx += tab_w + 6 * sc
	}
	draw_plot_config(app, cfg_rect)
}

// Draws the column-selection dropdowns for the active plot.
draw_plot_config :: proc(app: ^App, rect: rl.Rectangle) {
	t := app.themes[app.theme_index]
	sc := app.ui_scale
	rs := &app.results
	ds := active_dataset(rs)

	names := ds_column_names(ds)
	item_w := (rect.width - 3 * 10 * sc) / 4
	item_h := rect.height

	// Dropdown pairs for the active plot type.
	switch rs.plot.id {
	case PLOT_MAP:
		draw_dropdown(app, rl.Rectangle{rect.x, rect.y, item_w, item_h}, "Lat", names, &rs.plot.lat_col, &rs.plot.lat_open, &rs.plot.lat_scroll, t, sc)
		draw_dropdown(app, rl.Rectangle{rect.x + (item_w + 10 * sc), rect.y, item_w, item_h}, "Lon", names, &rs.plot.lon_col, &rs.plot.lon_open, &rs.plot.lon_scroll, t, sc)
	case PLOT_LINE:
		draw_dropdown(app, rl.Rectangle{rect.x, rect.y, item_w, item_h}, "X", names, &rs.plot.x_col, &rs.plot.x_open, &rs.plot.x_scroll, t, sc)
		draw_dropdown(app, rl.Rectangle{rect.x + (item_w + 10 * sc), rect.y, item_w, item_h}, "Y", names, &rs.plot.y_col, &rs.plot.y_open, &rs.plot.y_scroll, t, sc)
	case PLOT_HIST:
		draw_dropdown(app, rl.Rectangle{rect.x, rect.y, item_w * 2 + 10 * sc, item_h}, "Column", names, &rs.plot.h_col, &rs.plot.h_open, &rs.plot.h_scroll, t, sc)
	case PLOT_HIST2D:
		draw_dropdown(app, rl.Rectangle{rect.x, rect.y, item_w, item_h}, "X", names, &rs.plot.x_col, &rs.plot.x_open, &rs.plot.x_scroll, t, sc)
		draw_dropdown(app, rl.Rectangle{rect.x + (item_w + 10 * sc), rect.y, item_w, item_h}, "Y", names, &rs.plot.y_col, &rs.plot.y_open, &rs.plot.y_scroll, t, sc)
	}
}

// Dropdown button + scrollable popup list. `scroll` is the popup's first
// visible index; the wheel and Up/Down arrows scroll it, and Enter commits.
draw_dropdown :: proc(
	app: ^App,
	rect: rl.Rectangle,
	label: string,
	names: []string,
	sel: ^int,
	open: ^bool,
	scroll: ^int,
	theme: Theme,
	sc: f32,
) {
	// Clamp stale selections.
	if sel^ >= len(names) {
		sel^ = -1
	}

	mouse := rl.GetMousePosition()
	item_h := 22 * sc
	max_items := min(len(names), 12)

	// Button box.
	hover := rl.CheckCollisionPointRec(mouse, rect)
	bg := theme.axis_x if hover else theme.bg
	rl.DrawRectangleRec(rect, bg)
	rl.DrawRectangleLinesEx(rect, 1, theme.border)

	cur_text: string
	if sel^ >= 0 && sel^ < len(names) {
		cur_text = names[sel^]
	} else {
		cur_text = "auto"
	}
	txt := fmt.tprintf("%s: %s", label, cur_text)
	txt_c := strings.clone_to_cstring(txt, context.temp_allocator)
	draw_text(txt_c, c.int(rect.x + 8 * sc), c.int(rect.y + (rect.height - 14 * sc) * 0.5), i32(13 * sc), theme.text)

	if rl.CheckCollisionPointRec(mouse, rect) && rl.IsMouseButtonReleased(.LEFT) && !app.palette.open {
		open^ = !open^
	}

	// Popup list.
	if open^ {
		// Keyboard selection + scrolling (works without hovering the popup).
		if rl.IsKeyPressed(.DOWN) {
			if sel^ < 0 {
				sel^ = 0
			} else if sel^ < len(names) - 1 {
				sel^ += 1
			}
		}
		if rl.IsKeyPressed(.UP) {
			if sel^ < 0 {
				sel^ = len(names) - 1
			} else if sel^ > 0 {
				sel^ -= 1
			}
		}
		if rl.IsKeyPressed(.ENTER) {
			open^ = false
		}
		// Keep the selection visible.
		if sel^ >= 0 && sel^ < len(names) {
			if sel^ < scroll^ {
				scroll^ = sel^
			}
			if sel^ >= scroll^ + max_items {
				scroll^ = sel^ - max_items + 1
			}
		}

		popup_h := item_h * f32(max_items)
		popup := rl.Rectangle{rect.x, rect.y + rect.height, rect.width, popup_h}
		scroll^ = clamp(scroll^, 0, max(0, len(names) - max_items))

		// Wheel scrolls the visible window of items.
		if rl.CheckCollisionPointRec(mouse, popup) {
			scroll^ = clamp(scroll^ - int(rl.GetMouseWheelMove()), 0, max(0, len(names) - max_items))
		}

		rl.BeginScissorMode(c.int(popup.x), c.int(popup.y), c.int(popup.width), c.int(popup.height))
		rl.DrawRectangleRec(popup, rl.Color{30, 30, 40, 245})
		rl.DrawRectangleLinesEx(popup, 1, theme.border)
		for n in 0 ..< max_items {
			i := n + scroll^
			item := rl.Rectangle{popup.x, popup.y + f32(n) * item_h, popup.width, item_h}
			item_hover := rl.CheckCollisionPointRec(mouse, item)
			if item_hover {
				rl.DrawRectangleRec(item, rl.Fade(theme.axis_x, 0.4))
			}
			if i == sel^ {
				rl.DrawRectangleRec(item, rl.Fade(theme.axis_z, 0.25))
			}
			item_c := strings.clone_to_cstring(names[i], context.temp_allocator)
			draw_text(item_c, c.int(item.x + 6 * sc), c.int(item.y + 3 * sc), i32(12 * sc), theme.text)
			if item_hover && rl.IsMouseButtonReleased(.LEFT) {
				sel^ = i
				open^ = false
			}
		}
		rl.EndScissorMode()
	}

	// Close when clicking anywhere outside the button and popup.
	if open^ {
		in_popup := rl.CheckCollisionPointRec(mouse, rl.Rectangle{rect.x, rect.y + rect.height, rect.width, item_h * f32(max_items)})
		if rl.IsMouseButtonPressed(.LEFT) && !rl.CheckCollisionPointRec(mouse, rect) && !in_popup {
			open^ = false
		}
	}
}

results_any_dropdown_open :: proc(rs: ^Results_State) -> bool {
	return rs.plot.x_open || rs.plot.y_open || rs.plot.h_open || rs.plot.lat_open || rs.plot.lon_open
}

build_map_routes :: proc(app: ^App) -> []PlotRoute {
	rs := &app.results
	routes := make([dynamic]PlotRoute, 0, len(rs.datasets), context.temp_allocator)
	for ds, i in rs.datasets {
		if ds == nil {
			continue
		}
		lat, lon, auto_ok := ds_find_lat_lon(ds)
		// User-specified columns override auto-detection.
		if rs.plot.lat_col >= 0 && rs.plot.lat_col < len(ds.columns) {
			lat = &ds.columns[rs.plot.lat_col]
			auto_ok = lon != nil
		}
		if rs.plot.lon_col >= 0 && rs.plot.lon_col < len(ds.columns) {
			lon = &ds.columns[rs.plot.lon_col]
			auto_ok = lat != nil
		}
		if !auto_ok || lat == nil || lon == nil {
			continue
		}
		cache, ok := dataset_ensure_map_cache(ds, lat, lon)
		if !ok || cache == nil {
			continue
		}
		append(&routes, PlotRoute {
			name  = ds.name,
			color = PLOT_COLORS[i % len(PLOT_COLORS)],
			ds    = ds,
			cache = cache,
		})
	}
	return routes[:]
}

build_line_series :: proc(app: ^App, x_name, y_name: string) -> []PlotSeries {
	rs := &app.results
	series := make([dynamic]PlotSeries, 0, len(rs.datasets), context.temp_allocator)
	for ds, i in rs.datasets {
		if ds == nil {
			continue
		}
		xc := ds_column(ds, x_name)
		yc := ds_column(ds, y_name)
		if xc == nil || yc == nil {
			continue
		}
		pts := ds_series_xy(ds, xc, yc, MAX_PLOT_POINTS)
		if len(pts) == 0 {
			continue
		}
		append(&series, PlotSeries {
			name = ds.name,
			color = PLOT_COLORS[i % len(PLOT_COLORS)],
			points = pts,
		})
	}
	return series[:]
}

// --- raw data table ----------------------------------------------------------

results_compute_raw_widths :: proc(app: ^App) {
	rs := &app.results
	clear(&rs.raw_widths)
	ds := active_dataset(rs)
	if ds == nil {
		return
	}
	for &col in ds.columns {
		w := text_width_ui(col.name, 12, app.ui_scale)
		// sample first rows for content width
		for r in 0 ..< min(ds.n_rows, 100) {
			cell := format_cell(&col, r)
			if len(cell) == 0 {
				continue
			}
			w = max(w, text_width_ui(cell, 12, app.ui_scale))
		}
		w = max(w, RAW_COL_MIN_W * app.ui_scale)
		append(&rs.raw_widths, w)
	}
}

// Text width for raw-table cells. Falls back to a proportional estimate when
// the app font is not loaded yet (e.g. headless tests), where measure_text
// would dereference an empty font atlas.
text_width_ui :: proc(s: string, font_size: i32, sc: f32) -> f32 {
	if app_font.texture.id != 0 {
		return f32(measure_text(strings.clone_to_cstring(s, context.temp_allocator), font_size)) + 16 * sc
	}
	return f32(len(s)) * f32(font_size) * 0.55 + 16 * sc
}

draw_raw_table :: proc(app: ^App, rect: rl.Rectangle) {
	t := app.themes[app.theme_index]
	s := app.palette.style
	sc := app.ui_scale
	rs := &app.results

	rl.DrawRectangleRec(rect, s.panel)
	rl.DrawRectangleLinesEx(rect, 1, s.border)

	header_h := 26 * sc
	row_h := 20 * sc
	footer_h := 30 * sc // summary line + horizontal scrollbar

	ds := active_dataset(rs)
	if ds == nil {
		draw_text("No data selected", c.int(rect.x + 10 * sc), c.int(rect.y + 10 * sc), i32(13 * sc), rl.Fade(t.text, 0.6))
		return
	}
	if len(ds.columns) == 0 {
		draw_text("No columns", c.int(rect.x + 10 * sc), c.int(rect.y + 10 * sc), i32(13 * sc), rl.Fade(t.text, 0.6))
		return
	}

	// --- vertical scrolling (wheel + scrollbar drag) ------------------------
	viewport := rl.Rectangle{rect.x, rect.y + header_h, rect.width, rect.height - header_h - footer_h}
	rs.raw_scroll.content = f32(ds.n_rows) * row_h
	max_offset := max(rs.raw_scroll.content - viewport.height, 0)
	rs.raw_scroll.offset = clamp(rs.raw_scroll.offset, 0, max_offset)
	mouse := rl.GetMousePosition()
	if !app.palette.open {
		shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
		if rl.CheckCollisionPointRec(mouse, viewport) && !shift {
			rs.raw_scroll.offset = clamp(rs.raw_scroll.offset - rl.GetMouseWheelMove() * WHEEL_STEP * sc, 0, max_offset)
		}
		if max_offset > 0 {
			track := scroll_track(viewport, sc)
			thumb, _ := scroll_thumb_of(rs.raw_scroll, track, viewport.height, SCROLLBAR_MIN_THUMB * sc)
			if rl.IsMouseButtonPressed(.LEFT) {
				if rl.CheckCollisionPointRec(mouse, thumb) {
					rs.raw_scroll.dragging = true
					rs.raw_scroll.grab_off = mouse.y - thumb.y
				} else if rl.CheckCollisionPointRec(mouse, track) {
					rs.raw_scroll.dragging = true
					rs.raw_scroll.grab_off = thumb.height * 0.5
					rs.raw_scroll.offset =
						(mouse.y - thumb.height * 0.5 - track.y) /
						max(track.height - thumb.height, 1) *
						max_offset
				}
			}
			if rs.raw_scroll.dragging && rl.IsMouseButtonDown(.LEFT) {
				rs.raw_scroll.offset =
					(mouse.y - rs.raw_scroll.grab_off - track.y) /
					max(track.height - thumb.height, 1) *
					max_offset
			}
			if rl.IsMouseButtonReleased(.LEFT) {
				rs.raw_scroll.dragging = false
			}
			rs.raw_scroll.offset = clamp(rs.raw_scroll.offset, 0, max_offset)
		} else {
			rs.raw_scroll.dragging = false
		}
	}

	// --- rows (clipped below the header) ------------------------------------
	rl.BeginScissorMode(c.int(rect.x), c.int(rect.y + header_h), c.int(rect.width), c.int(viewport.height))
	row0 := int(rs.raw_scroll.offset / row_h)
	nvis := int(math.ceil(viewport.height / row_h)) + 1
	for r in row0 ..< min(ds.n_rows, row0 + nvis) {
		y := viewport.y + f32(r) * row_h - rs.raw_scroll.offset
		row_rect := rl.Rectangle{rect.x, y, rect.width, row_h}
		if r % 2 == 0 {
			rl.DrawRectangleRec(row_rect, rl.Fade(t.bg, 0.4))
		}
		draw_row_cells(app, rect, ds, rs.raw_widths[:], r, y, rs.raw_col_scroll, t, sc)
	}

	// vertical scrollbar
	if max_offset > 0 {
		track := scroll_track(viewport, sc)
		thumb, _ := scroll_thumb_of(rs.raw_scroll, track, viewport.height, SCROLLBAR_MIN_THUMB * sc)
		rl.DrawRectangleRec(track, t.bg)
		rl.DrawRectangleLinesEx(track, 1, t.border)
		rl.DrawRectangleRec(thumb, t.axis_x)
		rl.DrawRectangleLinesEx(thumb, 1, t.border)
	}
	rl.EndScissorMode()

	// header (fixed while the rows scroll) -----------------------------------
	rl.BeginScissorMode(c.int(rect.x), c.int(rect.y), c.int(rect.width), c.int(header_h))
	draw_row_cells(app, rect, ds, rs.raw_widths[:], -1, rect.y, rs.raw_col_scroll, t, sc)
	rl.EndScissorMode()

	// --- footer: horizontal scrollbar + summary ------------------------------
	total_w := 0.0
	for w in rs.raw_widths {
		total_w += f64(w)
	}
	if total_w > f64(rect.width) {
		rs.raw_col_scroll = clamp(rs.raw_col_scroll, 0, f32(total_w) - rect.width)
		if rl.IsKeyDown(.LEFT_SHIFT) {
			rs.raw_col_scroll -= rl.GetMouseWheelMove() * 30 * sc
		}
		bar := rl.Rectangle{rect.x, rect.y + rect.height - 8 * sc, rect.width, 8 * sc}
		rl.DrawRectangleRec(bar, t.bg)
		thumb_w := rect.width * rect.width / f32(total_w)
		thumb_x := bar.x + rs.raw_col_scroll / (f32(total_w) - rect.width) * (rect.width - thumb_w)
		rl.DrawRectangleRec(rl.Rectangle{thumb_x, bar.y, thumb_w, bar.height}, t.axis_x)
	}

	summary := fmt.ctprintf("%s · %d rows × %d cols", ds.name, ds.n_rows, len(ds.columns))
	draw_text(summary, c.int(rect.x + 10 * sc), c.int(rect.y + rect.height - 22 * sc), i32(11 * sc), rl.Fade(t.text, 0.5))
}

draw_row_cells :: proc(
	app: ^App,
	rect: rl.Rectangle,
	ds: ^Dataset,
	widths: []f32,
	row: int,
	row_y: f32,
	col_scroll: f32,
	theme: Theme,
	sc: f32,
) {
	x := rect.x + 6 * sc - col_scroll
	for cc, ci in ds.columns {
		w := widths[ci] if ci < len(widths) else RAW_COL_MIN_W * sc
		if x + w < rect.x || x > rect.x + rect.width {
			x += w
			continue
		}
		cell_rect := rl.Rectangle{x, row_y, w, 26 * sc if row < 0 else 20 * sc}
		cell_str := cc.name if row < 0 else format_cell(&ds.columns[ci], row)
		if len(cell_str) > 0 {
			col := theme.text if row < 0 else rl.Fade(theme.text, 0.85)
			cell_c := strings.clone_to_cstring(cell_str, context.temp_allocator)
			draw_text(cell_c, c.int(cell_rect.x + 4 * sc), c.int(cell_rect.y + 3 * sc), i32(12 * sc), col)
		}
		x += w
	}
}

format_cell :: proc(col: ^Column, row: int) -> string {
	if row < 0 || row >= len(col.floats) {
		return ""
	}
	if col.strs != nil && row < len(col.strs) && col.strs[row] != "" {
		return col.strs[row]
	}
	v := col.floats[row]
	if math.is_nan(v) {
		return ""
	}
	if col.type == .Bool {
		return "true" if v != 0 else "false"
	}
	// fmt.tprintf allocates on context.allocator; route it to the frame temp
	// allocator so per-frame cell formatting never leaks.
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%.6g", v)
	return strings.to_string(b)
}

// --- small widgets -----------------------------------------------------------

draw_button :: proc(rect: rl.Rectangle, label: cstring, theme: Theme, sc: f32) -> bool {
	mouse := rl.GetMousePosition()
	hover := rl.CheckCollisionPointRec(mouse, rect)
	bg := theme.axis_x if hover else theme.bg
	rl.DrawRectangleRec(rect, bg)
	rl.DrawRectangleLinesEx(rect, 1, theme.border)
	tw := f32(measure_text(label, i32(13 * sc)))
	draw_text(
		label,
		c.int(rect.x + (rect.width - tw) * 0.5),
		c.int(rect.y + (rect.height - 13 * sc) * 0.5),
		i32(13 * sc),
		theme.text,
	)
	return hover && rl.IsMouseButtonReleased(.LEFT)
}

draw_tab_button :: proc(rect: rl.Rectangle, label: cstring, active: bool, theme: Theme, sc: f32) -> bool {
	mouse := rl.GetMousePosition()
	hover := rl.CheckCollisionPointRec(mouse, rect)
	bg := theme.axis_x if active else (theme.bg if !hover else rl.Fade(theme.axis_x, 0.2))
	rl.DrawRectangleRec(rect, bg)
	rl.DrawRectangleLinesEx(rect, 1, theme.border)
	col := theme.bg if active else theme.text
	tw := f32(measure_text(label, i32(14 * sc)))
	draw_text(
		label,
		c.int(rect.x + (rect.width - tw) * 0.5),
		c.int(rect.y + (rect.height - 14 * sc) * 0.5),
		i32(14 * sc),
		col,
	)
	return hover && rl.IsMouseButtonReleased(.LEFT)
}

// Minimal text input. Returns true when Enter is pressed.
draw_text_input :: proc(
	rect: rl.Rectangle,
	buf: []u8,
	length: ^int,
	editing: ^bool,
	theme: Theme,
	sc: f32,
) -> bool {
	mouse := rl.GetMousePosition()
	hover := rl.CheckCollisionPointRec(mouse, rect)

	rl.DrawRectangleRec(rect, theme.bg)
	rl.DrawRectangleLinesEx(rect, 2 if editing^ else 1, theme.border if !editing^ else theme.axis_x)

	if rl.IsMouseButtonPressed(.LEFT) && hover {
		editing^ = true
	} else if rl.IsMouseButtonPressed(.LEFT) {
		editing^ = false
	}

	if editing^ {
		for {
			ch := rl.GetCharPressed()
			if ch == 0 {
				break
			}
			if ch >= 32 && ch <= 126 && length^ < len(buf) - 1 {
				buf[length^] = u8(ch)
				length^ += 1
			}
		}
		if rl.IsKeyPressed(.BACKSPACE) && length^ > 0 {
			length^ -= 1
			buf[length^] = 0
		}
	}

	text := string(buf[:length^])
	if len(text) > 0 {
		text_c := strings.clone_to_cstring(text, context.temp_allocator)
		draw_text(text_c, c.int(rect.x + 8 * sc), c.int(rect.y + (rect.height - 14 * sc) * 0.5), i32(14 * sc), theme.text)
	}
	if editing^ && i32(rl.GetTime() * 2) % 2 == 0 {
		cx := rect.x + 8 * sc + f32(measure_text(strings.clone_to_cstring(text, context.temp_allocator), i32(14 * sc)))
		rl.DrawLine(
			c.int(cx),
			c.int(rect.y + 5 * sc),
			c.int(cx),
			c.int(rect.y + rect.height - 5 * sc),
			theme.axis_z,
		)
	}

	if editing^ && rl.IsKeyPressed(.ENTER) {
		editing^ = false
		return true
	}
	if editing^ && rl.IsKeyPressed(.ESCAPE) {
		editing^ = false
	}
	return false
}