package palantir

// Results explorer view: browse a folder for .csv/.json files, multi-select
// them, choose one of the available plots (Map / Line / Scatter /
// Histogram / 2D histogram), and inspect the raw data in a virtualized table
// that only renders the rows that are actually visible.

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:sort"
import "core:strings"
import rl "vendor:raylib"

RECENT_CMD_BASE :: 2000
// Reserve a distinct user_data range for the folder-navigation palette
// commands (kept above the recents range).
FOLDER_CMD_BASE :: 4000
RECENT_MAX :: 12
MAX_PLOT_POINTS :: 20000
RAW_COL_MIN_W :: 90

PLOT_MAP :: 0
PLOT_LINE :: 1
PLOT_SCATTER :: 2
PLOT_HIST :: 3
PLOT_HIST2D :: 4
PLOT_MESH3D :: 5

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
	z_col:   int,
	h_col:   int,
	lat_col: int,
	lon_col: int,
	// Dropdown popup state.
	x_open, y_open, z_open, h_open, lat_open, lon_open: bool,
	// Per-dropdown popup scroll offset (index into the column list).
	x_scroll, y_scroll, z_scroll, h_scroll, lat_scroll, lon_scroll: int,
	// Plot-selector dropdown popup state.
	plot_open: bool,
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
	// Horizontal raw-table scrollbar drag state.
	raw_col_dragging: bool,
	raw_col_grab_off: f32,
	raw_widths:    [dynamic]f32,
	// Shared filter box for the column dropdowns (only one popup ever open).
	col_filter:    [64]u8,
	col_filter_len: int,
	// Command-palette folder navigation: parent + subdirectories of `root`,
	// rebuilt whenever the folder is rescanned. Owns the name/path strings.
	folder_cmds:   [dynamic]Palette_Command,
	show_left_panel: bool,
	show_bottom_panel: bool,
	show_recents:  bool,
	search_buf:    [256]u8,
	search_len:    int,
	search_edit:   bool,
	// True for the frame a text input consumed Enter, so the file-browser
	// keyboard navigation can't also act on that same keypress.
	text_enter:    bool,
	plot:          Results_Plot,
	map_view:      Map_View,
	map_bg:        Map_Background,
	map_bg_init:   bool,
	msg:           string,
	// 3D mesh viewer state (see mesh.odin / mesh_view.odin).
	mesh:          ^Mesh_Dataset,
	mesh_path:     string, // path the cached mesh was loaded from
	mesh_view:     Mesh_View,
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
		z_col = -1,
		h_col = -1,
		lat_col = -1,
		lon_col = -1,
	}
	rs.map_view = Map_View{center_lon = 0, center_lat = 25, lon_span = 360}
	rs.show_left_panel = true
	rs.show_bottom_panel = true
	rs.mesh_view = mesh_view_init()
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
	for fc in rs.folder_cmds {
		delete(fc.name)
		delete(fc.description)
	}
	delete(rs.folder_cmds)
	if rs.root != "" {
		delete(rs.root)
	}
	if rs.msg != "" {
		delete(rs.msg)
	}
	destroy_map_background(&rs.map_bg)
	results_destroy_mesh(app)
}

results_destroy_mesh :: proc(app: ^App) {
	rs := &app.results
	if rs.mesh != nil {
		mesh_destroy(rs.mesh)
		free(rs.mesh)
		rs.mesh = nil
	}
	if rs.mesh_path != "" {
		delete(rs.mesh_path)
		rs.mesh_path = ""
	}
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
	// Keep the palette's folder-navigation list in sync with the new listing.
	refresh_palette_folders(app)
}

// Rebuilds the folder-navigation command list for the current root: a ".."
// parent entry (when there is one) followed by every subdirectory. Owned by
// `folder_cmds` so the palette can borrow the slice safely across rescans.
refresh_palette_folders :: proc(app: ^App) {
	rs := &app.results
	for fc in rs.folder_cmds {
		delete(fc.name)
		delete(fc.description)
	}
	clear(&rs.folder_cmds)
	if len(rs.root) == 0 {
		return
	}

	parent := filepath.dir(rs.root)
	if parent != rs.root {
		append(&rs.folder_cmds, Palette_Command {
			name        = strings.clone(".."),
			description = strings.clone(parent),
			user_data   = rawptr(uintptr(FOLDER_CMD_BASE)),
		})
	}
	for e in rs.entries {
		if !e.is_dir {
			continue
		}
		append(&rs.folder_cmds, Palette_Command {
			name        = strings.clone(e.name),
			description = strings.clone(e.path),
			user_data   = rawptr(uintptr(FOLDER_CMD_BASE + len(rs.folder_cmds))),
		})
	}
}

// Opens the command palette focused on folder navigation for the current root.
// Esc takes you back to the normal palette.
open_folder_palette :: proc(app: ^App) {
	refresh_palette_folders(app)
	// Copy the folder list into a palette-owned buffer. `folder_cmds` is freed
	// and rebuilt on every `results_scan`; pointing the palette at it directly
	// would leave `commands` referencing freed strings the moment a folder is
	// selected (the Ctrl+G crash).
	for fc in app.palette_folder_children {
		delete(fc.name)
		delete(fc.description)
	}
	clear(&app.palette_folder_children)
	for fc in app.results.folder_cmds {
		append(&app.palette_folder_children, Palette_Command {
			name        = strings.clone(fc.name),
			description = strings.clone(fc.description),
			user_data   = fc.user_data,
		})
	}
	palette_open_it(&app.palette)
	if len(app.palette_folder_children) > 0 {
		palette_push_layer(&app.palette)
		app.palette.commands = app.palette_folder_children[:]
		palette_reset(&app.palette)
		// Populate matches now so the folder list draws immediately instead of
		// showing "No command found" for one frame.
		palette_refresh_matches(&app.palette)
	}
}

// Jumps the browser into the folder selected in the folder palette.
// `path` must be an owned/stable string (the palette command's description),
// never a slice into `folder_cmds` — that list is freed by `results_scan`.
results_handle_folder_select :: proc(app: ^App, path: string) {
	if len(path) == 0 {
		return
	}
	results_set_root(app, path)
	app.results.show_recents = false
}

results_set_root :: proc(app: ^App, path: string) {
	rs := &app.results
	// Snapshot `path` before mutating anything: callers may pass a slice that
	// lives inside `rs.root` (results_go_up) or inside `app.recents`
	// (results_open_recent), both of which are freed below / in
	// results_add_recent_folder. Reading `path` after that is a use-after-free.
	new_root := strings.clone(path)
	if rs.root != "" {
		delete(rs.root)
	}
	rs.root = new_root
	// Remember the folder so the Recents view shows recent folders.
	results_add_recent_folder(app, new_root)
	// Keep the path input box in sync with the current folder.
	rs.path_len = min(len(new_root), len(rs.path_buf) - 1)
	for i in 0 ..< rs.path_len {
		rs.path_buf[i] = new_root[i]
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

// Backspace handler for the path input box. When the path sits at a folder
// boundary (trailing '/'), it removes the last segment and navigates up one
// folder, returning true to suppress character deletion. Otherwise it returns
// false so the box deletes a character normally.
path_input_backspace :: proc(app: ^App, text: string) -> bool {
	if len(text) == 0 || text[len(text) - 1] != '/' {
		return false
	}
	stripped := text[:len(text) - 1]
	if len(stripped) == 0 {
		return true // at the filesystem root; consume the key
	}
	parent := filepath.dir(stripped)
	if parent == stripped {
		return true // no parent to go to; consume the key
	}
	results_set_root(app, parent)
	return true
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

// Records a browsed folder in the recents list (most recent first, deduped,
// capped at RECENT_MAX). Called on every folder navigation so the Recents view
// remembers folders, not result files.
results_add_recent_folder :: proc(app: ^App, folder: string) {
	if len(folder) == 0 {
		return
	}
	// Snapshot the folder: it may point into `app.recents` (results_open_recent),
	// and the dedup `delete(p)` below frees that exact buffer before we re-add it.
	owned := strings.clone(folder)
	defer delete(owned)
	// Dedup: collect the surviving entries (everything except `owned`).
	survivors := make([dynamic]string, 0, len(app.recents), context.temp_allocator)
	for p in app.recents {
		if p != owned {
			append(&survivors, p)
		} else {
			delete(p)
		}
	}
	// The old backing array is freed; the surviving strings are moved on.
	delete(app.recents)

	new_len := min(len(survivors) + 1, RECENT_MAX)
	out := make([]string, new_len, context.allocator)
	out[0] = strings.clone(owned)
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

results_open_folder :: proc(app: ^App, folder: string) {
	if len(folder) == 0 {
		return
	}
	if !os.exists(folder) {
		results_msg(app, "Folder no longer exists")
		return
	}
	results_set_root(app, folder)
	app.results.show_recents = false
}

results_open_recent :: proc(app: ^App, idx: int) {
	if idx < 0 || idx >= len(app.recents) {
		return
	}
	results_open_folder(app, app.recents[idx])
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
	app.results.map_bg_init = false
}

open_recents_view :: proc(app: ^App) {
	app.results.show_recents = true
}

results_toggle_left_panel :: proc(app: ^App) {
	app.results.show_left_panel = !app.results.show_left_panel
}

results_toggle_bottom_panel :: proc(app: ^App) {
	app.results.show_bottom_panel = !app.results.show_bottom_panel
}

// Focuses the file-browser search box (Ctrl+F / "Find files").
results_focus_search :: proc(app: ^App) {
	rs := &app.results
	rs.search_edit = true
	rs.path_edit = false
	rs.show_recents = false
}

// Reloads the selected datasets from disk so plots reflect changed files.
results_reload_datasets :: proc(app: ^App) {
	rs := &app.results
	for ds in rs.datasets {
		if ds != nil {
			dataset_destroy(ds)
			free(ds)
		}
	}
	clear(&rs.datasets)
	// results_sync_datasets reloads every path still in rs.selected.
	results_sync_datasets(app)
}

// Ctrl+R / "Refresh plots": re-scan the folder and reload the selected data,
// preserving the current selection across the rescan.
results_refresh :: proc(app: ^App) {
	rs := &app.results
	selected_paths := make([dynamic]string, 0, len(rs.selected), context.temp_allocator)
	for idx in rs.selected {
		if idx >= 0 && idx < len(rs.entries) {
			append(&selected_paths, strings.clone(rs.entries[idx].path, context.temp_allocator))
		}
	}
	results_scan(app)
	clear(&rs.selected)
	for p in selected_paths {
		for e, i in rs.entries {
			if !e.is_dir && e.path == p {
				append(&rs.selected, i)
				break
			}
		}
	}
	results_reload_datasets(app)
}

// Global keyboard shortcuts for the results explorer (ignored while the
// command palette is open). Ctrl+F focuses search, Ctrl+R refreshes,
// Ctrl+L/Ctrl+B toggle the left/bottom panels, and Ctrl+1..5 switch
// the active plot type.
results_handle_shortcuts :: proc(app: ^App) {
	if app.palette.open {
		return
	}
	rs := &app.results
	if ctrl_held() {
		if rl.IsKeyPressed(.F) {
			results_focus_search(app)
		}
		if rl.IsKeyPressed(.R) {
			results_refresh(app)
		}
		if rl.IsKeyPressed(.L) {
			results_toggle_left_panel(app)
		}
		if rl.IsKeyPressed(.B) {
			results_toggle_bottom_panel(app)
		}
		// Ctrl+G opens the folder-selection palette for the current root.
		if rl.IsKeyPressed(.G) {
			open_folder_palette(app)
		}
		if rl.IsKeyPressed(.ONE) {rs.plot.id = PLOT_MAP}
		if rl.IsKeyPressed(.TWO) {rs.plot.id = PLOT_LINE}
		if rl.IsKeyPressed(.THREE) {rs.plot.id = PLOT_SCATTER}
		if rl.IsKeyPressed(.FOUR) {rs.plot.id = PLOT_HIST}
		if rl.IsKeyPressed(.FIVE) {rs.plot.id = PLOT_HIST2D}
		if rl.IsKeyPressed(.SIX) {rs.plot.id = PLOT_MESH3D}
	}
}

// --- palette recents submenu -------------------------------------------------

refresh_palette_recents :: proc(app: ^App) {
	// The palette owns its recent entries (clones), so it never borrows
	// `app.recents` strings that get freed/reallocated on navigation.
	for c in app.palette_recent_children {
		delete(c.name)
		delete(c.description)
	}
	clear(&app.palette_recent_children)
	for p, i in app.recents {
		append(&app.palette_recent_children, Palette_Command {
			name = strings.clone(file_base_name(p)),
			description = strings.clone(p),
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
	sc := app.ui_scale
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	rs := &app.results
	rs.text_enter = false

	results_handle_shortcuts(app)

	// Discard queued characters while no text field is focused, so stale input
	// can never be injected into a box the moment it is clicked. A dropdown's
	// column filter captures typing while open, so it also pauses the discard.
	if !app.palette.open && !rs.path_edit && !rs.search_edit && !results_any_dropdown_open(rs) {
		for rl.GetCharPressed() != 0 {}
	}

	// --- top bar: path input + actions -------------------------------------
	pad := 10 * sc
	top := pad
	bar_h := 36 * sc
	btn_w := 88 * sc
	gap := 8 * sc
	refresh_rect := rl.Rectangle{sw - pad - btn_w, top, btn_w, bar_h}
	bottom_toggle_w := 96 * sc
	left_toggle_w := 82 * sc
	bottom_toggle_rect := rl.Rectangle{refresh_rect.x - gap - bottom_toggle_w, top, bottom_toggle_w, bar_h}
	left_toggle_rect := rl.Rectangle{bottom_toggle_rect.x - gap - left_toggle_w, top, left_toggle_w, bar_h}
	recents_rect := rl.Rectangle{left_toggle_rect.x - gap - btn_w, top, btn_w, bar_h}
	up_rect := rl.Rectangle{recents_rect.x - gap - 56 * sc, top, 56 * sc, bar_h}
	path_rect := rl.Rectangle{pad, top, up_rect.x - pad - gap, bar_h}

	if draw_text_input(
		app,
		path_rect,
		rs.path_buf[:],
		&rs.path_len,
		&rs.path_edit,
		t,
		sc,
		"Folder path",
		path_input_backspace,
	) {
		rs.text_enter = true
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
	if draw_button(left_toggle_rect, "Left On" if rs.show_left_panel else "Left Off", t, sc) {
		results_toggle_left_panel(app)
	}
	if draw_button(bottom_toggle_rect, "Bottom On" if rs.show_bottom_panel else "Bottom Off", t, sc) {
		results_toggle_bottom_panel(app)
	}
	if draw_button(refresh_rect, "Refresh", t, sc) {
		results_refresh(app)
	}

	if rs.msg != "" {
		msg_c := strings.clone_to_cstring(rs.msg, context.temp_allocator)
		draw_text(msg_c, c.int(pad), c.int(top + bar_h + 4 * sc), i32(12 * sc), t.axis_z)
	}

	// --- layout -------------------------------------------------------------
	// Keep the raw table a fixed-ish strip (caps at ~14% of the screen) so on
	// tall 4K windows the plot panel always absorbs the extra vertical space.
	msg_gap := f32(18 * sc) if rs.msg != "" else 0
	bottom_h := clamp(sh * 0.14, 160 * sc, 220 * sc)
	body_top := top + bar_h + pad + msg_gap
	body_bottom := sh - bottom_h - pad if rs.show_bottom_panel else sh - pad
	left_w := 320 * sc
	left := rl.Rectangle{pad, body_top, left_w, body_bottom - body_top}
	right := rl.Rectangle{pad, body_top, sw - 2 * pad, body_bottom - body_top}
	if rs.show_left_panel {
		right = rl.Rectangle {
			left.x + left.width + pad,
			body_top,
			sw - (left.x + left.width + pad) - pad,
			body_bottom - body_top,
		}
	}
	raw := rl.Rectangle{pad, body_bottom + pad, sw - 2 * pad, sh - body_bottom - 2 * pad}

	// --- left panel ----------------------------------------------------------
	if rs.show_left_panel {
		if rs.show_recents {
			draw_recents_panel(app, left)
		} else {
			draw_file_browser(app, left)
		}
	}

	// --- right panel: plot ---------------------------------------------------
	draw_plot_panel(app, right)

	// --- bottom panel: raw data ---------------------------------------------
	if rs.show_bottom_panel {
		draw_raw_table(app, raw)
	}
}

// Indices (into rs.entries) that match the current search query. An empty
// query returns every entry, so the browser always lists all dirs + .csv/.json.
results_filtered_entries :: proc(app: ^App) -> []int {
	rs := &app.results
	query := strings.to_lower(string(rs.search_buf[:rs.search_len]), context.temp_allocator)
	out := make([dynamic]int, 0, len(rs.entries), context.temp_allocator)
	for e, i in rs.entries {
		if len(query) == 0 {
			append(&out, i)
			continue
		}
		if strings.contains(strings.to_lower(e.name, context.temp_allocator), query) {
			append(&out, i)
		}
	}
	return out[:]
}

// Maps a visible row (the keyboard cursor position) to an entry index. Returns
// -1 for the ".." parent row or when the row is out of range.
results_entry_at_cursor :: proc(app: ^App, filtered: []int, has_parent: bool) -> int {
	rs := &app.results
	row := rs.file_cursor
	if has_parent {
		if row == 0 {
			return -1
		}
		row -= 1
	}
	if row < 0 || row >= len(filtered) {
		return -1
	}
	return filtered[row]
}

draw_file_browser :: proc(app: ^App, panel: rl.Rectangle) {
	t := app.themes[app.theme_index]
	sc := app.ui_scale
	rs := &app.results

	draw_panel(panel, t, sc, true)

	title_h := 28 * sc
	draw_text("Files", c.int(panel.x + 12 * sc), c.int(panel.y + 8 * sc), i32(15 * sc), t.text)

	sel_count := fmt.ctprintf("%d selected", len(rs.selected))
	draw_text(
		sel_count,
		c.int(panel.x + panel.width - f32(measure_text(sel_count, i32(12 * sc))) - 12 * sc),
		c.int(panel.y + 10 * sc),
		i32(12 * sc),
		t.muted,
	)

	// Search box filters the listing to matching dirs, .csv and .json files.
	search_h := 30 * sc
	search_rect := rl.Rectangle{panel.x + 10 * sc, panel.y + title_h + 2 * sc, panel.width - 20 * sc, search_h}
	if draw_text_input(app, search_rect, rs.search_buf[:], &rs.search_len, &rs.search_edit, t, sc, "Search files (Ctrl+F)") {
		rs.text_enter = true
	}

	filtered := results_filtered_entries(app)

	viewport := rl.Rectangle {
		panel.x,
		panel.y + title_h + search_h + 8 * sc,
		panel.width,
		panel.height - title_h - search_h - 8 * sc,
	}

	row_h := 28 * sc
	pitch := row_h + 2 * sc
	has_parent := len(rs.root) > 0 && filepath.dir(rs.root) != rs.root
	total_rows := len(filtered) + 1 if has_parent else len(filtered)
	if total_rows > 0 {
		rs.file_cursor = clamp(rs.file_cursor, 0, total_rows - 1)
	}

	// Keyboard navigation (gated so it never fights the palette, the path
	// input, the search box, an open dropdown, or an Enter a text box just
	// consumed this frame).
	if !app.palette.open && !app.palette_just_closed && !rs.path_edit && !rs.search_edit && !rs.text_enter && !results_any_dropdown_open(rs) {
		root_changed := false
		if total_rows > 0 && rl.IsKeyPressed(.DOWN) {
			rs.file_cursor = min(rs.file_cursor + 1, total_rows - 1)
		}
		if total_rows > 0 && rl.IsKeyPressed(.UP) {
			rs.file_cursor = max(rs.file_cursor - 1, 0)
		}
		if rl.IsKeyPressed(.LEFT) {
			prev_root := rs.root
			results_go_up(app)
			root_changed = root_changed || rs.root != prev_root
		}
		if rl.IsKeyPressed(.BACKSPACE) {
			prev_root := rs.root
			results_go_up(app)
			root_changed = root_changed || rs.root != prev_root
		}
		if rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressed(.ENTER) {
			if rs.file_cursor == 0 && has_parent {
				prev_root := rs.root
				results_go_up(app)
				root_changed = root_changed || rs.root != prev_root
			} else {
				entry_idx := results_entry_at_cursor(app, filtered, has_parent)
				if entry_idx >= 0 && entry_idx < len(rs.entries) {
					if rs.entries[entry_idx].is_dir {
						prev_root := rs.root
						results_set_root(app, rs.entries[entry_idx].path)
						root_changed = root_changed || rs.root != prev_root
					} else {
						results_select_only(app, entry_idx)
					}
				}
			}
		}
		if root_changed {
			// Keyboard navigation can change folders; rebuild derived row state so
			// we never render using stale indices from the previous listing.
			filtered = results_filtered_entries(app)
			has_parent = len(rs.root) > 0 && filepath.dir(rs.root) != rs.root
			total_rows = len(filtered) + 1 if has_parent else len(filtered)
			if total_rows > 0 {
				rs.file_cursor = clamp(rs.file_cursor, 0, total_rows - 1)
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

	row_i := 0
	if has_parent {
		row := ui_alloc(&u, row_h, 2 * sc)
		draw_row(row, "..", true, false, row_i == rs.file_cursor, t, sc)
		row_i += 1
	}

	for fi in filtered {
		e := rs.entries[fi]
		row := ui_alloc(&u, row_h, 2 * sc)
		selected := false
		for s2 in rs.selected {
			if s2 == fi {
				selected = true
				break
			}
		}
		draw_row(row, e.name, e.is_dir, selected, row_i == rs.file_cursor, t, sc)
		row_i += 1
	}
	ui_scroll_end(&u, &rs.file_scroll, viewport, t, sc)

	// Row interaction. Clicks on the scrollbar track are ignored so scrolling
	// never accidentally selects the file under the cursor.
	mouse := rl.GetMousePosition()
	track := scroll_track(viewport, sc)
	if !app.palette.open &&
	   rl.IsMouseButtonReleased(.LEFT) &&
	   rl.CheckCollisionPointRec(mouse, viewport) &&
	   !rl.CheckCollisionPointRec(mouse, track) {
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
		if row0 >= 0 && row0 < len(filtered) {
			fi := filtered[row0]
			ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
			if rs.entries[fi].is_dir {
				results_set_root(app, rs.entries[fi].path)
			} else if ctrl {
				results_toggle_select(app, fi)
			} else {
				results_select_only(app, fi)
			}
		}
	}
}

draw_row :: proc(
	row: rl.Rectangle,
	label: string,
	is_dir, selected, cursor: bool,
	theme: Theme,
	sc: f32,
) {
	mouse := rl.GetMousePosition()
	hover := rl.CheckCollisionPointRec(mouse, row)
	if selected {
		draw_fill_rounded(row, rl.Fade(theme.accent, 0.18), UI_RADIUS_SM * sc)
	} else if cursor || hover {
		draw_fill_rounded(row, theme.hover, UI_RADIUS_SM * sc)
	}
	icon_s := 13 * sc
	icon_x := row.x + 8 * sc
	icon_y := row.y + (row.height - icon_s) * 0.5
	if is_dir {
		draw_icon_folder(icon_x, icon_y, icon_s, theme.axis_y)
	} else {
		draw_icon_check(icon_x, icon_y, icon_s, selected, theme)
	}
	name_c := strings.clone_to_cstring(label, context.temp_allocator)
	col := theme.axis_y if is_dir else theme.text
	draw_text(name_c, c.int(row.x + 28 * sc), c.int(row.y + (row.height - 13 * sc) * 0.5), i32(13 * sc), col)
}

draw_icon_folder :: proc(x, y, s: f32, col: rl.Color) {
	tab := rl.Rectangle{x, y + s * 0.12, s * 0.42, s * 0.22}
	body := rl.Rectangle{x, y + s * 0.30, s, s * 0.58}
	draw_fill_rounded(tab, col, 2)
	draw_fill_rounded(body, col, 2)
}

draw_icon_check :: proc(x, y, s: f32, on: bool, theme: Theme) {
	box := rl.Rectangle{x, y, s, s}
	if on {
		draw_fill_rounded(box, theme.accent, 3)
		a := rl.Vector2{x + s * 0.22, y + s * 0.52}
		b := rl.Vector2{x + s * 0.42, y + s * 0.72}
		p := rl.Vector2{x + s * 0.78, y + s * 0.28}
		rl.DrawLineEx(a, b, 1.7, theme.accent_text)
		rl.DrawLineEx(b, p, 1.7, theme.accent_text)
	} else {
		draw_stroke_rounded(box, theme.border, 3, 1)
	}
}

draw_recents_panel :: proc(app: ^App, panel: rl.Rectangle) {
	t := app.themes[app.theme_index]
	sc := app.ui_scale
	rs := &app.results

	draw_panel(panel, t, sc, true)

	title_h := 28 * sc
	draw_text("Recent folders", c.int(panel.x + 12 * sc), c.int(panel.y + 8 * sc), i32(15 * sc), t.text)

	clear_rect := rl.Rectangle{panel.x + panel.width - 92 * sc, panel.y + 6 * sc, 80 * sc, 24 * sc}
	if draw_button(clear_rect, "Clear", t, sc) {
		results_clear_recents(app)
	}

	back_rect := rl.Rectangle{panel.x + 10 * sc, panel.y + title_h + 4 * sc, 120 * sc, 26 * sc}
	if draw_button(back_rect, "Browse", t, sc) {
		rs.show_recents = false
	}

	viewport := rl.Rectangle{panel.x, panel.y + title_h + 36 * sc, panel.width, panel.height - title_h - 36 * sc}
	rl.BeginScissorMode(
		c.int(viewport.x),
		c.int(viewport.y),
		c.int(viewport.width),
		c.int(viewport.height),
	)
	u := ui_scroll_begin(&rs.dir_scroll, viewport, sc, !app.palette.open)

	row_h := 36 * sc
	pitch := row_h + 4 * sc
	if len(app.recents) == 0 {
		row := ui_alloc(&u, row_h)
		draw_text("No recent folders yet", c.int(row.x + 8 * sc), c.int(row.y + 8 * sc), i32(13 * sc), t.muted)
	}
	for p in app.recents {
		row := ui_alloc(&u, row_h, 4 * sc)
		hover := rl.CheckCollisionPointRec(rl.GetMousePosition(), row)
		if hover {
			draw_fill_rounded(row, t.hover, UI_RADIUS_SM * sc)
		}
		icon_s := 14 * sc
		draw_icon_folder(row.x + 8 * sc, row.y + (row.height - icon_s) * 0.5, icon_s, t.axis_y)
		name_c := strings.clone_to_cstring(file_base_name(p), context.temp_allocator)
		draw_text(name_c, c.int(row.x + 30 * sc), c.int(row.y + 4 * sc), i32(13 * sc), t.text)
		path_c := strings.clone_to_cstring(p, context.temp_allocator)
		draw_text(path_c, c.int(row.x + 30 * sc), c.int(row.y + 18 * sc), i32(11 * sc), t.muted)
	}
	ui_scroll_end(&u, &rs.dir_scroll, viewport, t, sc)

	mouse := rl.GetMousePosition()
	track := scroll_track(viewport, sc)
	if !app.palette.open &&
	   rl.IsMouseButtonReleased(.LEFT) &&
	   rl.CheckCollisionPointRec(mouse, viewport) &&
	   !rl.CheckCollisionPointRec(mouse, track) {
		idx := int((mouse.y - (viewport.y + SCROLLBAR_PAD * sc) + rs.dir_scroll.offset) / pitch)
		if idx >= 0 && idx < len(app.recents) {
			results_open_recent(app, idx)
		}
	}
}

// --- plot panel --------------------------------------------------------------

PLOT_NAMES := [?]string{"Map", "Line", "Scatter", "Histogram", "2D", "Mesh"}

draw_plot_selector :: proc(app: ^App, rect: rl.Rectangle, theme: Theme, sc: f32) {
	rs := &app.results
	n := len(PLOT_NAMES)
	radius := UI_RADIUS_SM * sc
	draw_fill_rounded(rect, theme.window_bg, radius)
	draw_stroke_rounded(rect, theme.border, radius, 1)

	item_w := rect.width / f32(n)
	mouse := rl.GetMousePosition()
	inset := 3 * sc
	for i in 0 ..< n {
		item := rl.Rectangle{rect.x + f32(i) * item_w, rect.y, item_w, rect.height}
		hover := rl.CheckCollisionPointRec(mouse, item) && !app.palette.open
		if i == rs.plot.id {
			pill := rl.Rectangle{item.x + inset, item.y + inset, item.width - 2 * inset, item.height - 2 * inset}
			draw_fill_rounded(pill, theme.accent, radius - 1)
		} else if hover {
			pill := rl.Rectangle{item.x + inset, item.y + inset, item.width - 2 * inset, item.height - 2 * inset}
			draw_fill_rounded(pill, theme.hover, radius - 1)
		}
		col := theme.accent_text if i == rs.plot.id else theme.text
		name_c := strings.clone_to_cstring(PLOT_NAMES[i], context.temp_allocator)
		fs := i32(12 * sc)
		tw := f32(measure_text(name_c, fs))
		draw_text(
			name_c,
			c.int(item.x + (item.width - tw) * 0.5),
			c.int(item.y + (item.height - f32(fs)) * 0.5),
			fs,
			col,
		)
		if hover && rl.IsMouseButtonReleased(.LEFT) {
			rs.plot.id = i
			rs.plot.plot_open = false
			results_close_column_popups(&app.results)
		}
	}
}

draw_empty_plot :: proc(rect: rl.Rectangle, message: cstring, theme: Theme, sc: f32) {
	draw_fill_rounded(rect, theme.window_bg, UI_RADIUS_SM * sc)
	draw_text(message, c.int(rect.x + 14 * sc), c.int(rect.y + 14 * sc), i32(13 * sc), theme.muted)
}

draw_plot_panel :: proc(app: ^App, panel: rl.Rectangle) {
	t := app.themes[app.theme_index]
	sc := app.ui_scale
	rs := &app.results

	draw_panel(panel, t, sc, true)
	inset := 10 * sc
	inner := rl.Rectangle{panel.x + inset, panel.y + inset, panel.width - 2 * inset, panel.height - 2 * inset}

	tab_h := 32 * sc
	cfg_h := 34 * sc
	cfg_rect := rl.Rectangle{inner.x, inner.y + tab_h + 8 * sc, inner.width, cfg_h}

	plot_rect := rl.Rectangle {
		inner.x,
		inner.y + tab_h + cfg_h + 16 * sc,
		inner.width,
		inner.height - tab_h - cfg_h - 16 * sc,
	}

	fs := i32(12 * sc)
	if len(rs.datasets) == 0 {
		draw_empty_plot(plot_rect, "Select one or more .csv / .json files to plot", t, sc)
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
				draw_empty_plot(plot_rect, "No lat/lon columns in the selected files", t, sc)
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

		case PLOT_LINE, PLOT_SCATTER:
			x_name := results_col_name(app, rs.plot.x_col)
			y_name := results_col_name(app, rs.plot.y_col)
			if x_name == "" || y_name == "" {
				draw_empty_plot(plot_rect, "Pick x and y columns", t, sc)
			} else {
				hue_name := results_col_name(app, rs.plot.h_col)
				series := build_line_series(app, x_name, y_name, hue_name)
				if len(series) == 0 {
					draw_empty_plot(plot_rect, "No data", t, sc)
				} else {
					x_label := x_name
					xc := active_dataset(rs)
					if xc != nil {
						cx_col := ds_column(xc, x_name)
						if is_time_column(cx_col) {
							x_label = "time (s)"
						}
					}
					title := "Scatter plot" if rs.plot.id == PLOT_SCATTER else "Line plot"
					plot_series(app, series, title, x_label, y_name, plot_rect, t, fs, sc, rs.plot.id == PLOT_SCATTER)
				}
			}

		case PLOT_HIST:
			ds := active_dataset(rs)
			if ds != nil {
				h_name := results_col_name(app, rs.plot.h_col)
				if h_name == "" {
					draw_empty_plot(plot_rect, "Pick a column", t, sc)
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
					draw_empty_plot(plot_rect, "Pick x and y columns", t, sc)
				} else {
					xc := ds_column(ds, x_name)
					yc := ds_column(ds, y_name)
					pts := ds_series_xy(ds, xc, yc, 100000)
					if len(pts) == 0 {
						draw_empty_plot(plot_rect, "No data", t, sc)
					} else {
						plot_histogram_2d(app, pts, "2D histogram", x_name, y_name, 0, 0, plot_rect, t, fs, sc)
					}
				}
			}

		case PLOT_MESH3D:
			ds := active_dataset(rs)
			if ds == nil {
				draw_empty_plot(plot_rect, "Select a .json mesh file", t, sc)
			} else {
				mesh := results_ensure_mesh(app, ds)
				if mesh == nil {
					draw_empty_plot(plot_rect, "Failed to load mesh (need vertices + triangles)", t, sc)
				} else {
					xi, yi, zi, ci := results_mesh_field_indices(app, mesh)
					if xi < 0 || yi < 0 || zi < 0 {
						draw_empty_plot(plot_rect, "Pick X, Y and Z fields", t, sc)
					} else {
						draw_mesh_view(app, mesh, xi, yi, zi, ci, plot_rect, t, sc)
					}
				}
			}
	}
	}

	// Column config is drawn before the plot selector, so when the selector's
	// dropdown is open its opaque popup paints cleanly over the config row
	// (standard dropdown cover) instead of the two rows colliding. Both render
	// after the plot so their popups stay on top of it.
	draw_plot_config(app, cfg_rect)
	draw_plot_selector(app, rl.Rectangle{inner.x, inner.y, inner.width, tab_h}, t, sc)
}

// Fuzzy word filter for the column dropdowns: every whitespace-delimited term
// in `query` must match somewhere in `name` (case-insensitive substring, same
// rule as the command palette). Empty query matches everything.
fuzzy_words_match :: proc(name, query: string) -> bool {
	if len(query) == 0 {
		return true
	}
	words := strings.fields(query, context.temp_allocator)
	for w in words {
		if !palette_fuzzy_contains(name, w) {
			return false
		}
	}
	return true
}

// Lays out `labels` as equal-width dropdowns filling `rect` and draws them.
// Used by the column-config row so every plot type shares one slotting rule.
draw_dropdown_row :: proc(
	app: ^App,
	rect: rl.Rectangle,
	labels: []string,
	sels: []^int,
	opens: []^bool,
	scrolls: []^int,
	names: []string,
	theme: Theme,
	sc: f32,
) {
	n := min(len(labels), len(sels), len(opens), len(scrolls))
	if n == 0 {
		return
	}
	gap := 10 * sc
	item_w := (rect.width - f32(n - 1) * gap) / f32(n)
	for i in 0 ..< n {
		r := rl.Rectangle {rect.x + f32(i) * (item_w + gap), rect.y, item_w, rect.height}
		draw_dropdown(app, r, labels[i], names, sels[i], opens[i], scrolls[i], theme, sc)
	}
}

// Draws the column-selection dropdowns for the active plot.
draw_plot_config :: proc(app: ^App, rect: rl.Rectangle) {
	t := app.themes[app.theme_index]
	sc := app.ui_scale
	rs := &app.results

	names := ds_column_names(active_dataset(rs))
	if rs.plot.id == PLOT_MESH3D {
		names = mesh_field_names(rs.mesh)
	}

	// Dropdown pairs for the active plot type. Line/Scatter additionally get a
	// "Hue" dropdown that colors points by a third column (seaborn-style).
	switch rs.plot.id {
	case PLOT_MAP:
		draw_dropdown_row(app, rect, {"Lat", "Lon"}, {&rs.plot.lat_col, &rs.plot.lon_col}, {&rs.plot.lat_open, &rs.plot.lon_open}, {&rs.plot.lat_scroll, &rs.plot.lon_scroll}, names, t, sc)
	case PLOT_LINE, PLOT_SCATTER:
		draw_dropdown_row(app, rect, {"X", "Y", "Hue"}, {&rs.plot.x_col, &rs.plot.y_col, &rs.plot.h_col}, {&rs.plot.x_open, &rs.plot.y_open, &rs.plot.h_open}, {&rs.plot.x_scroll, &rs.plot.y_scroll, &rs.plot.h_scroll}, names, t, sc)
	case PLOT_HIST:
		draw_dropdown_row(app, rect, {"Column"}, {&rs.plot.h_col}, {&rs.plot.h_open}, {&rs.plot.h_scroll}, names, t, sc)
	case PLOT_HIST2D:
		draw_dropdown_row(app, rect, {"X", "Y"}, {&rs.plot.x_col, &rs.plot.y_col}, {&rs.plot.x_open, &rs.plot.y_open}, {&rs.plot.x_scroll, &rs.plot.y_scroll}, names, t, sc)
	case PLOT_MESH3D:
		draw_dropdown_row(app, rect, {"X", "Y", "Z", "Color"}, {&rs.plot.x_col, &rs.plot.y_col, &rs.plot.z_col, &rs.plot.h_col}, {&rs.plot.x_open, &rs.plot.y_open, &rs.plot.z_open, &rs.plot.h_open}, {&rs.plot.x_scroll, &rs.plot.y_scroll, &rs.plot.z_scroll, &rs.plot.h_scroll}, names, t, sc)
	}
}

// --- 3D mesh helpers ---------------------------------------------------------

// Loads (and caches) the mesh for the active dataset's path.
results_ensure_mesh :: proc(app: ^App, ds: ^Dataset) -> ^Mesh_Dataset {
	rs := &app.results
	if rs.mesh != nil && rs.mesh_path == ds.path {
		return rs.mesh
	}
	results_destroy_mesh(app)
	if m, ok := load_mesh_dataset(ds.path, ds.name); ok {
		rs.mesh = m
		rs.mesh_path = strings.clone(ds.path)
		rs.mesh_view.fit = true
		return m
	}
	return nil
}

// Resolves a selected field index (or -1 = auto) to a mesh field index, falling
// back to a named auto-detection.
results_mesh_field_idx :: proc(m: ^Mesh_Dataset, sel: int, auto: string) -> int {
	if sel >= 0 && sel < len(m.fields) {
		return sel
	}
	for f, i in m.fields {
		if equal_ci(f.name, auto) {
			return i
		}
	}
	return -1
}

// X/Y/Z/Color field indices for the mesh viewer.
results_mesh_field_indices :: proc(app: ^App, m: ^Mesh_Dataset) -> (xi, yi, zi, ci: int) {
	rs := &app.results
	xi = results_mesh_field_idx(m, rs.plot.x_col, "x")
	yi = results_mesh_field_idx(m, rs.plot.y_col, "y")
	zi = results_mesh_field_idx(m, rs.plot.z_col, "z")
	ci = results_mesh_field_idx(m, rs.plot.h_col, "vmag")
	if ci < 0 {
		ci = results_mesh_field_idx(m, rs.plot.h_col, "phi")
	}
	if ci == xi || ci == yi || ci == zi {
		ci = -1
	}
	return
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
	radius := UI_RADIUS_SM * sc
	draw_fill_rounded(rect, theme.hover if hover else theme.window_bg, radius)
	draw_stroke_rounded(rect, theme.accent if hover else theme.border, radius, 1)

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
		if !open^ {
			results_close_column_popups(&app.results, open)
			app.results.col_filter_len = 0
		}
		app.results.plot.plot_open = false
		open^ = !open^
	}

	search_h := 24 * sc

	// Popup list.
	if open^ {
		rs := &app.results

		// Filter box typing (only one popup open at a time, shared buffer).
		for {
			ch := rl.GetCharPressed()
			if ch == 0 {
				break
			}
			if ch >= 32 && ch <= 126 && rs.col_filter_len < len(rs.col_filter) - 1 {
				rs.col_filter[rs.col_filter_len] = u8(ch)
				rs.col_filter_len += 1
			}
		}
		if rl.IsKeyPressed(.BACKSPACE) && rs.col_filter_len > 0 {
			rs.col_filter_len -= 1
			rs.col_filter[rs.col_filter_len] = 0
		}
		if rl.IsKeyPressed(.ESCAPE) {
			open^ = false
		}

		// Fuzzy word filter over the column names.
		filtered := make([dynamic]int, 0, len(names), context.temp_allocator)
		query := string(rs.col_filter[:rs.col_filter_len])
		for name, i in names {
			if fuzzy_words_match(name, query) {
				append(&filtered, i)
			}
		}
		count := len(filtered)

		// Position of the current selection within the filtered list.
		cur_pos := -1
		if sel^ >= 0 {
			for fp, actual in filtered {
				if actual == sel^ {
					cur_pos = fp
					break
				}
			}
		}

		// Keyboard selection + scrolling (works without hovering the popup).
		if rl.IsKeyPressed(.DOWN) {
			if cur_pos < 0 {
				cur_pos = 0 if count > 0 else -1
			} else if cur_pos < count - 1 {
				cur_pos += 1
			}
		}
		if rl.IsKeyPressed(.UP) {
			if cur_pos < 0 {
				cur_pos = count - 1
			} else if cur_pos > 0 {
				cur_pos -= 1
			}
		}
		if rl.IsKeyPressed(.ENTER) {
			if cur_pos >= 0 && cur_pos < count {
				sel^ = filtered[cur_pos]
			}
			open^ = false
		}
		if cur_pos >= 0 && cur_pos < count {
			sel^ = filtered[cur_pos]
		}

		// Keep the selection visible (scroll is a position in the filtered list).
		if cur_pos >= 0 && cur_pos < count {
			if cur_pos < scroll^ {
				scroll^ = cur_pos
			}
			if cur_pos >= scroll^ + max_items {
				scroll^ = cur_pos - max_items + 1
			}
		}
		max_scroll := max(count - max_items, 0)
		scroll^ = clamp(scroll^, 0, max_scroll)

		popup_h := search_h + item_h * f32(max_items) + 6 * sc
		popup := rl.Rectangle{rect.x, rect.y + rect.height, rect.width, popup_h}

		// Wheel scrolls the visible window of items.
		if rl.CheckCollisionPointRec(mouse, popup) {
			scroll^ = clamp(scroll^ - int(rl.GetMouseWheelMove()), 0, max_scroll)
		}

		rl.BeginScissorMode(c.int(popup.x), c.int(popup.y), c.int(popup.width), c.int(popup.height))
		draw_shadow(popup, sc, UI_RADIUS_SM * sc)
		draw_fill_rounded(popup, theme.bg, UI_RADIUS_SM * sc)
		draw_stroke_rounded(popup, theme.border, UI_RADIUS_SM * sc, 1)

		// Filter box at the top of the popup.
		search_rect := rl.Rectangle{popup.x + 4 * sc, popup.y + 4 * sc, popup.width - 8 * sc, search_h - 4 * sc}
		draw_fill_rounded(search_rect, theme.window_bg, 4 * sc)
		draw_stroke_rounded(search_rect, theme.border, 4 * sc, 1)
		ftext := string(rs.col_filter[:rs.col_filter_len])
		if len(ftext) > 0 {
			ftext_c := strings.clone_to_cstring(ftext, context.temp_allocator)
			draw_text(
				ftext_c,
				c.int(search_rect.x + 4 * sc),
				c.int(search_rect.y + (search_rect.height - 12 * sc) * 0.5),
				i32(12 * sc),
				theme.text,
			)
		} else {
			hint_c := strings.clone_to_cstring("filter…", context.temp_allocator)
			draw_text(
				hint_c,
				c.int(search_rect.x + 4 * sc),
				c.int(search_rect.y + (search_rect.height - 12 * sc) * 0.5),
				i32(12 * sc),
				theme.muted,
			)
		}

		// Items, drawn from the filtered list.
		list_top := popup.y + search_h
		visible := min(max_items, count)
		for n in 0 ..< visible {
			fp := n + scroll^
			actual := filtered[fp]
			item := rl.Rectangle{popup.x, list_top + f32(n) * item_h, popup.width, item_h}
			item_hover := rl.CheckCollisionPointRec(mouse, item)
			if fp == cur_pos {
				draw_fill_rounded(item, rl.Fade(theme.accent, 0.22), 4 * sc)
			} else if item_hover {
				draw_fill_rounded(item, theme.hover, 4 * sc)
			}
			item_c := strings.clone_to_cstring(names[actual], context.temp_allocator)
			draw_text(item_c, c.int(item.x + 6 * sc), c.int(item.y + 3 * sc), i32(12 * sc), theme.text)
			if item_hover && rl.IsMouseButtonReleased(.LEFT) {
				sel^ = actual
				open^ = false
			}
		}
		rl.EndScissorMode()
	}

	// Close when clicking anywhere outside the button and popup.
	if open^ {
		popup := rl.Rectangle{rect.x, rect.y + rect.height, rect.width, search_h + item_h * f32(max_items) + 6 * sc}
		in_popup := rl.CheckCollisionPointRec(mouse, popup)
		if rl.IsMouseButtonPressed(.LEFT) && !rl.CheckCollisionPointRec(mouse, rect) && !in_popup {
			open^ = false
		}
	}
}

// Closes every column dropdown popup except `keep` (nil = close all). Used to
// guarantee only one popup is ever open, so the plot selector's dropdown never
// overlaps the column-config popups.
results_close_column_popups :: proc(rs: ^Results_State, keep: ^bool = nil) {
	popups := [?]^bool {&rs.plot.x_open, &rs.plot.y_open, &rs.plot.z_open, &rs.plot.h_open, &rs.plot.lat_open, &rs.plot.lon_open}
	for p in popups {
		if p != keep {
			p^ = false
		}
	}
}

results_any_dropdown_open :: proc(rs: ^Results_State) -> bool {
	return rs.plot.x_open || rs.plot.y_open || rs.plot.z_open || rs.plot.h_open || rs.plot.lat_open || rs.plot.lon_open || rs.plot.plot_open
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

// Builds the per-dataset series for the Line/Scatter plot. When `hue_name` is
// non-empty, each series also carries stride-sampled hue values aligned with
// its points; datasets without that column are skipped.
build_line_series :: proc(app: ^App, x_name, y_name: string, hue_name := "") -> []PlotSeries {
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
		ps := PlotSeries {
			name     = ds.name,
			color    = PLOT_COLORS[i % len(PLOT_COLORS)],
			points   = pts,
			hue_name = hue_name,
		}
		if hue_name != "" {
			hc := ds_column(ds, hue_name)
			if hc == nil {
				continue
			}
			ps.hue = ds_series_hue(ds, hc, MAX_PLOT_POINTS)
		}
		append(&series, ps)
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
	sc := app.ui_scale
	rs := &app.results

	draw_panel(rect, t, sc, true)

	header_h := 26 * sc
	row_h := 20 * sc
	footer_h := 30 * sc // summary line + horizontal scrollbar

	ds := active_dataset(rs)
	if ds == nil {
		draw_text("No data selected", c.int(rect.x + 12 * sc), c.int(rect.y + 12 * sc), i32(13 * sc), t.muted)
		return
	}
	if len(ds.columns) == 0 {
		draw_text("No columns", c.int(rect.x + 12 * sc), c.int(rect.y + 12 * sc), i32(13 * sc), t.muted)
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
			rl.DrawRectangleRec(row_rect, rl.Fade(t.hover, 0.5))
		}
		draw_row_cells(app, rect, ds, rs.raw_widths[:], r, y, rs.raw_col_scroll, t, sc)
	}

	// vertical scrollbar
	if max_offset > 0 {
		track := scroll_track(viewport, sc)
		thumb, _ := scroll_thumb_of(rs.raw_scroll, track, viewport.height, SCROLLBAR_MIN_THUMB * sc)
		draw_scrollbar(track, thumb, t, sc)
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
		max_col := f32(total_w) - rect.width
		rs.raw_col_scroll = clamp(rs.raw_col_scroll, 0, max_col)

		bar_h := 10 * sc
		bar := rl.Rectangle{rect.x, rect.y + rect.height - bar_h - 2 * sc, rect.width, bar_h}
		track := bar
		thumb_w := max(rect.width * rect.width / f32(total_w), 24 * sc)
		thumb_x := bar.x + rs.raw_col_scroll / max_col * (rect.width - thumb_w)
		thumb := rl.Rectangle{thumb_x, bar.y, thumb_w, bar.height}

		if !app.palette.open {
			// Shift+wheel scrolls horizontally over the table area.
			shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
			if rl.GetMouseWheelMove() != 0 && shift {
				rs.raw_col_scroll = clamp(
					rs.raw_col_scroll - rl.GetMouseWheelMove() * WHEEL_STEP * sc,
					0,
					max_col,
				)
			}
			// Click and drag on the scrollbar.
			if rl.IsMouseButtonPressed(.LEFT) {
				if rl.CheckCollisionPointRec(mouse, thumb) {
					rs.raw_col_dragging = true
					rs.raw_col_grab_off = mouse.x - thumb.x
				} else if rl.CheckCollisionPointRec(mouse, track) {
					rs.raw_col_dragging = true
					rs.raw_col_grab_off = thumb.width * 0.5
					rs.raw_col_scroll = clamp(
						(mouse.x - thumb.width * 0.5 - track.x) /
						max(track.width - thumb_w, 1) *
						max_col,
						0,
						max_col,
					)
				}
			}
			if rs.raw_col_dragging && rl.IsMouseButtonDown(.LEFT) {
				rs.raw_col_scroll = clamp(
					(mouse.x - rs.raw_col_grab_off - track.x) /
					max(track.width - thumb_w, 1) *
					max_col,
					0,
					max_col,
				)
			}
			if rl.IsMouseButtonReleased(.LEFT) {
				rs.raw_col_dragging = false
			}
		} else {
			rs.raw_col_dragging = false
		}

		draw_scrollbar(track, thumb, t, sc)
	}

	summary := fmt.ctprintf("%s · %d rows × %d cols", ds.name, ds.n_rows, len(ds.columns))
	draw_text(summary, c.int(rect.x + 12 * sc), c.int(rect.y + rect.height - 22 * sc), i32(11 * sc), t.muted)
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
	pressed := hover && rl.IsMouseButtonDown(.LEFT)
	radius := UI_RADIUS_SM * sc
	bg := theme.bg
	if pressed {
		bg = rl.Fade(theme.accent, 0.18)
	} else if hover {
		bg = theme.hover
	}
	draw_fill_rounded(rect, bg, radius)
	draw_stroke_rounded(rect, theme.accent if hover else theme.border, radius, 1)
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

// Minimal text input. Returns true when Enter is pressed. `hint` (optional) is
// shown faded when the box is empty and not being edited. When `on_backspace`
// is provided and returns true, the Backspace is considered handled (e.g. the
// caller navigated up a folder) and no character is deleted.
draw_text_input :: proc(
	app: ^App,
	rect: rl.Rectangle,
	buf: []u8,
	length: ^int,
	editing: ^bool,
	theme: Theme,
	sc: f32,
	hint: cstring = nil,
	on_backspace: proc(app: ^App, text: string) -> bool = nil,
) -> bool {
	mouse := rl.GetMousePosition()
	hover := rl.CheckCollisionPointRec(mouse, rect)

	radius := UI_RADIUS_SM * sc
	draw_fill_rounded(rect, theme.window_bg, radius)
	border := theme.accent if editing^ else theme.border
	thick: f32 = 2.0 if editing^ else 1.0
	draw_stroke_rounded(rect, border, radius, thick)

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
		if rl.IsKeyPressed(.BACKSPACE) {
			if on_backspace != nil && on_backspace(app, string(buf[:length^])) {
				// handled (navigation); do not delete a character
			} else if length^ > 0 {
				length^ -= 1
				buf[length^] = 0
			}
		}
	}

	text := string(buf[:length^])
	if len(text) > 0 {
		text_c := strings.clone_to_cstring(text, context.temp_allocator)
		draw_text(text_c, c.int(rect.x + 8 * sc), c.int(rect.y + (rect.height - 14 * sc) * 0.5), i32(14 * sc), theme.text)
	} else if hint != nil && !editing^ {
		draw_text(hint, c.int(rect.x + 8 * sc), c.int(rect.y + (rect.height - 14 * sc) * 0.5), i32(14 * sc), theme.muted)
	}
	if editing^ && i32(rl.GetTime() * 2) % 2 == 0 {
		cx := rect.x + 8 * sc + f32(measure_text(strings.clone_to_cstring(text, context.temp_allocator), i32(14 * sc)))
		rl.DrawLine(
			c.int(cx),
			c.int(rect.y + 5 * sc),
			c.int(cx),
			c.int(rect.y + rect.height - 5 * sc),
			theme.accent,
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