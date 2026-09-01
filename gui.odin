package palantir

// Application shell: owns the raylib window and a reusable command palette,
// and draws the results explorer view.
//
// The lifecycle procs (`init`, `update`, `shutdown`, `should_run`,
// `parent_window_size_changed`) mirror the karl-zylinski/odin-raylib-web
// structure so the exact same code drives both the native desktop build and
// the wasm/web build. `run` is the native entry point used by `main.odin`.
//
// The reusable pieces live in sibling files:
//   - `palette.odin`  — command palette widget (self-contained, no app state)
//   - `ui_layout.odin`— flow-layout cursor, scroll regions, themes
//   - `ui_font.odin`  — app font plus `draw_text`/`measure_text` wrappers
//   - the `plot_*` procs in this file are raylib-only and can be reused in any
//     raylib program.

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:sort"
import "core:strings"
import rl "vendor:raylib"

App :: struct {
	running:                 bool,
	themes:                  [len(BASE_THEMES)]Theme,
	theme_index:             int,
	ui_scale_zoom:           f32, // user-adjustable multiplier on the detected UI scale
	ui_scale:                f32, // clamped base scale * zoom, used for all UI metrics
	palette:                 Command_Palette,
	// True for one frame after the palette consumes input and closes, so the
	// file browser cannot also react to the same keypress (e.g. the Enter that
	// navigated a Ctrl+G folder selection would otherwise re-fire on the fresh
	// listing's ".." row and bounce straight back to the parent folder).
	palette_just_closed:     bool,
	// Results explorer state (see results_view.odin).
	results:                 Results_State,
	// Plot PNG export feedback (see plot_export.odin).
	export_count:            int,
	exporting:               bool,
	save_feedback_at:        f64,
	save_feedback_title:     string,
	// Recently opened files, persisted in the settings file.
	recents:                 []string,
	recents_dirty:           bool,
	// Dynamic palette command root so the "Open recents" submenu can be
	// rebuilt at runtime (see refresh_palette_recents).
	palette_root:            [dynamic]Palette_Command,
	palette_recent_children: [dynamic]Palette_Command,
	// Palette-owned copy of the folder-navigation command list. The palette
	// must never borrow `results.folder_cmds` directly: that list is freed and
	// rebuilt on every folder scan, which would leave the palette pointing at
	// freed strings (the Ctrl+G "select folder" crash).
	palette_folder_children: [dynamic]Palette_Command,
}

App_Config :: struct {
	width:      i32,
	height:     i32,
	title:      cstring,
	target_fps: i32,
}

default_config :: proc() -> App_Config {
	return App_Config{width = 1280, height = 720, title = "Palantir", target_fps = 60}
}

// Persisted between runs in the platform config directory (native builds only);
// see settings_path below.
App_Settings :: struct {
	theme_index:    int,
	window_width:   i32,
	window_height:  i32,
	// Multiplier on the auto-detected UI scale; adjustable live with +/-/0.
	ui_scale_zoom:  f32,
	// Recently browsed folders (most recent first).
	recent_folders: []string,
	// Last active plot type + the last column selection per slot, remembered
	// by name so they survive restarts and dataset reloads.
	plot_id:        int,
	plot_x_col:     string,
	plot_y_col:     string,
	plot_z_col:     string,
	plot_h_col:     string,
	plot_u_col:     string,
	plot_v_col:     string,
	plot_w_col:     string,
	plot_lat_col:   string,
	plot_lon_col:   string,
}

// Location of the persisted settings file, kept out of the working directory so
// the app can run from anywhere:
//   Linux:   $XDG_CONFIG_HOME/palantir, defaulting to ~/.config/palantir
//   macOS:   ~/Library/Application Support/palantir
//   Windows: %APPDATA%/palantir
// Returns "" when no config directory can be determined or on web builds.
settings_dir :: proc() -> string {
	when ODIN_OS == .Windows {
		if base := os.get_env("APPDATA", context.allocator); base != "" {
			defer delete(base)
			return strings.concatenate({base, "\\palantir"})
		}
	} else when ODIN_OS == .Darwin {
		if home := os.get_env("HOME", context.allocator); home != "" {
			defer delete(home)
			return strings.concatenate({home, "/Library/Application Support/palantir"})
		}
	} else when ODIN_OS != .JS {
		if xdg := os.get_env("XDG_CONFIG_HOME", context.allocator); xdg != "" {
			defer delete(xdg)
			return strings.concatenate({xdg, "/palantir"})
		}
		if home := os.get_env("HOME", context.allocator); home != "" {
			defer delete(home)
			return strings.concatenate({home, "/.config/palantir"})
		}
	}
	return ""
}

// Full path to the settings file (settings_dir + "palantir_gui.json"), creating
// the directory on demand. Falls back to a file in the working directory when no
// platform config directory is available. Returns "" on web builds. The caller
// owns the returned string.
settings_path :: proc() -> string {
	when ODIN_OS == .JS {
		return ""
	} else {
		if dir := settings_dir(); dir != "" {
			defer delete(dir)
			_ = os.make_directory_all(dir)
			return strings.concatenate({dir, "/palantir_gui.json"})
		}
		return "palantir_gui.json"
	}
}

default_settings :: proc() -> App_Settings {
	cfg := default_config()
	return App_Settings {
		theme_index = 0,
		window_width = cfg.width,
		window_height = cfg.height,
		ui_scale_zoom = 1,
	}
}

load_settings :: proc() -> App_Settings {
	s := default_settings()
	when ODIN_OS != .JS {
		if path := settings_path(); path != "" {
			defer delete(path)
			if data, err := os.read_entire_file_from_path(path, context.allocator);
			   err == nil {
				defer delete(data)
				_ = json.unmarshal(data, &s)
			}
		}
	}
	if s.ui_scale_zoom <= 0 {s.ui_scale_zoom = 1}
	return s
}

save_settings :: proc(app: ^App) {
	when ODIN_OS != .JS {
		if !rl.IsWindowReady() {
			return // e.g. headless tests: no window/DPI context to read
		}
		// Refresh the remembered column names from the live selections.
		results_sync_remembered(app)
		dpi := rl.GetWindowScaleDPI()
		scl := max(dpi.x, dpi.y, 1)
		s := App_Settings {
			theme_index    = app.theme_index,
			window_width   = i32(math.round(f32(rl.GetScreenWidth()) / scl)),
			window_height  = i32(math.round(f32(rl.GetScreenHeight()) / scl)),
			ui_scale_zoom  = app.ui_scale_zoom,
			recent_folders = app.recents,
			plot_id        = app.results.plot.id,
			plot_x_col     = app.results.remembered.x,
			plot_y_col     = app.results.remembered.y,
			plot_z_col     = app.results.remembered.z,
			plot_h_col     = app.results.remembered.h,
			plot_u_col     = app.results.remembered.u,
			plot_v_col     = app.results.remembered.v,
			plot_w_col     = app.results.remembered.w,
			plot_lat_col   = app.results.remembered.lat,
			plot_lon_col   = app.results.remembered.lon,
		}
		if data, err := json.marshal(s); err == nil {
			defer delete(data)
			if path := settings_path(); path != "" {
				defer delete(path)
				if werr := os.write_entire_file(path, data); werr != nil {
					fmt.eprintfln("[gui] could not save settings: %v", werr)
				}
			}
		}
	}
}

// Type-checked command set for the palette. Each value is wired to a display
// name, description, and optional subcommands in `gui_commands` below;
// dispatch is a `switch` on this enum (see `on_palette_select`), never a
// string comparison.
GuiCommand :: enum {
	// Parents: open a submenu, never dispatched.
	theme,
	recent_files,
	goto_folder,

	// Leaves.
	theme_rosepine,
	theme_mocha,
	theme_vesper,
	open_results_folder,
	open_recents,
	find_files,
	refresh_plots,
	toggle_left_panel,
	toggle_bottom_panel,
	quit,
}

// The palette command tree. `user_data` carries the `GuiCommand` enum so
// `on_palette_select` can `switch` on it. All static data: no runtime
// allocation. The "Open recents" children are replaced dynamically with the
// current recent-file list by `refresh_palette_recents`.
gui_commands := [?]Palette_Command {
	{
		name = "Theme",
		description = "switch the color theme",
		user_data = rawptr(uintptr(GuiCommand.theme)),
		children = []Palette_Command {
			{
				name = "Rosepine Dawn",
				description = "default light theme",
				user_data = rawptr(uintptr(GuiCommand.theme_rosepine)),
			},
			{
				name = "Catppuccino Mocha",
				description = "dark theme",
				user_data = rawptr(uintptr(GuiCommand.theme_mocha)),
			},
			{
				name = "Vesper",
				description = "near-black theme",
				user_data = rawptr(uintptr(GuiCommand.theme_vesper)),
			},
		},
	},
	{
		name = "Open results folder",
		description = "browse .csv / .json result files",
		user_data = rawptr(uintptr(GuiCommand.open_results_folder)),
	},
	{
		name = "Open recents",
		description = "open the recent folders view",
		user_data = rawptr(uintptr(GuiCommand.open_recents)),
	},
	{
		name = "Find files",
		description = "focus the file search box",
		user_data = rawptr(uintptr(GuiCommand.find_files)),
	},
	{
		name = "Refresh plots",
		description = "reload selected result files",
		user_data = rawptr(uintptr(GuiCommand.refresh_plots)),
	},
	{
		name = "Toggle left panel",
		description = "show/hide the files/recents panel",
		user_data = rawptr(uintptr(GuiCommand.toggle_left_panel)),
	},
	{
		name = "Toggle bottom panel",
		description = "show/hide the raw data table",
		user_data = rawptr(uintptr(GuiCommand.toggle_bottom_panel)),
	},
	{
		name        = "Recent folders",
		description = "recently browsed folders",
		user_data   = rawptr(uintptr(GuiCommand.recent_files)),
		// Children are replaced dynamically with the current recent-folder list by
		// `refresh_palette_recents`.
		children    = nil,
	},
	{
		name = "Go to folder",
		description = "browse the current folder's subdirectories",
		user_data = rawptr(uintptr(GuiCommand.goto_folder)),
	},
	{name = "Quit", description = "close the GUI", user_data = rawptr(uintptr(GuiCommand.quit))},
}

// Single instance backing the web entry points, which are `proc "c"` and thus
// cannot carry an `App` argument. Native callers may use `app_run` directly.
default_app: App

// --- native entry point ---------------------------------------------------

run :: proc() {
	app_run(&default_app, default_config())
}

app_run :: proc(app: ^App, config := App_Config{}) {
	cfg := config if config.title != nil else default_config()
	app_init(app, cfg)
	defer app_shutdown(app)

	for app_should_run(app) {
		app_update(app)
	}
}

// --- app lifecycle (struct based, fully reusable) -------------------------

app_init :: proc(app: ^App, config := App_Config{}) {
	cfg := config if config.title != nil else default_config()
	settings := load_settings()
	if settings.window_width > 0 && settings.window_height > 0 {
		cfg.width = settings.window_width
		cfg.height = settings.window_height
	}
	app.running = true
	app.themes = BASE_THEMES
	app.theme_index =
		settings.theme_index if settings.theme_index >= 0 && settings.theme_index < len(app.themes) else 0

	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT, .WINDOW_HIGHDPI})
	rl.InitWindow(cfg.width, cfg.height, cfg.title)
	mon := rl.GetCurrentMonitor()
	max_w := rl.GetMonitorWidth(mon)
	max_h := rl.GetMonitorHeight(mon)
	if cfg.width > max_w || cfg.height > max_h {
		rl.SetWindowSize(min(cfg.width, max_w), min(cfg.height, max_h))
	}
	rl.SetTargetFPS(cfg.target_fps)
	rl.SetExitKey(.KEY_NULL) // Esc closes the palette, not the app.
	load_app_font()
	rl.GuiSetFont(app_font)

	app.ui_scale_zoom = settings.ui_scale_zoom
	app.ui_scale = clamp(detect_base_ui_scale() * app.ui_scale_zoom, UI_SCALE_MIN, UI_SCALE_MAX)
	app.palette.ui_scale = app.ui_scale

	app.recents = settings.recent_folders
	results_init(app)
	// Restore the last plot type and column selections (by name).
	rs := &app.results
	rs.remembered = Plot_Columns {
		x   = settings.plot_x_col,
		y   = settings.plot_y_col,
		z   = settings.plot_z_col,
		h   = settings.plot_h_col,
		u   = settings.plot_u_col,
		v   = settings.plot_v_col,
		w   = settings.plot_w_col,
		lat = settings.plot_lat_col,
		lon = settings.plot_lon_col,
	}
	rs.plot.id = clamp(settings.plot_id, 0, len(PLOT_NAMES) - 1)
	cwd, _ := os.get_working_directory(context.temp_allocator)
	results_set_root(app, cwd)
	refresh_palette_recents(app)
	palette_init(
		&app.palette,
		app.palette_root[:],
		on_palette_select,
		palette_style_for_theme(app.themes[app.theme_index], app.ui_scale),
	)
}

app_shutdown :: proc(app: ^App) {
	save_settings(app)
	results_destroy(app)
	for p in app.recents {
		delete(p)
	}
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
	palette_destroy(&app.palette)
	unload_app_font()
	rl.CloseWindow()
}

app_should_run :: proc(app: ^App) -> bool {
	when ODIN_OS != .JS {
		// Never call this on web: it contains a 16 ms sleep there.
		if rl.WindowShouldClose() {
			app.running = false
		}
	}
	return app.running
}

app_update :: proc(app: ^App) {
	if app.recents_dirty {
		refresh_palette_recents(app)
		app.recents_dirty = false
	}
	palette_toggle_on_shortcut(&app.palette)
	// Capture whether the palette owned this frame's input before it runs; if it
	// closes here, the rest of the frame must not act on the same keypresses.
	palette_was_open := app.palette.open
	palette_update(&app.palette)
	app.palette_just_closed = palette_was_open && !app.palette.open
	handle_ui_zoom(app)

	rl.BeginDrawing()
	t := app.themes[app.theme_index]
	app.palette.style = palette_style_for_theme(t, app.ui_scale)
	rl.ClearBackground(t.window_bg)
	draw_results_view(app)

	palette_draw(&app.palette, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()))
	rl.EndDrawing()

	free_all(context.temp_allocator)
}

// Best-effort UI scale for the current display: the max of the OS-reported
// content scale, a resolution heuristic (1080p -> 1.0, 4K -> 2.0), and a
// physical-DPI estimate. Never below 1.0.
detect_base_ui_scale :: proc() -> f32 {
	scale := f32(1)

	dpi := rl.GetWindowScaleDPI()
	scale = max(scale, max(dpi.x, dpi.y))

	monitor := rl.GetCurrentMonitor()
	mon_w := rl.GetMonitorWidth(monitor)
	mon_h := rl.GetMonitorHeight(monitor)

	if mon_h > 0 {
		scale = max(scale, f32(mon_h) / 1080)
	}

	phys_w := rl.GetMonitorPhysicalWidth(monitor)
	phys_h := rl.GetMonitorPhysicalHeight(monitor)
	if mon_w > 0 && mon_h > 0 && phys_w > 0 && phys_h > 0 {
		dpi_x := f32(mon_w) / (f32(phys_w) / 25.4)
		dpi_y := f32(mon_h) / (f32(phys_h) / 25.4)
		scale = max(scale, max(dpi_x, dpi_y) / 96)
	}

	return max(scale, 1)
}

// Zoom the whole UI with + / -; 0 resets to the auto-detected scale.
// Skipped while the palette is open so typing is not hijacked.
handle_ui_zoom :: proc(app: ^App) {
	if app.palette.open {
		return
	}
	before := app.ui_scale_zoom
	if rl.IsKeyPressed(.EQUAL) || rl.IsKeyPressed(.KP_ADD) {
		app.ui_scale_zoom *= UI_SCALE_STEP
	}
	if rl.IsKeyPressed(.MINUS) || rl.IsKeyPressed(.KP_SUBTRACT) {
		app.ui_scale_zoom /= UI_SCALE_STEP
	}
	if rl.IsKeyPressed(.ZERO) {
		app.ui_scale_zoom = 1
	}
	if app.ui_scale_zoom != before {
		app.ui_scale = clamp(
			detect_base_ui_scale() * app.ui_scale_zoom,
			UI_SCALE_MIN,
			UI_SCALE_MAX,
		)
		app.palette.ui_scale = app.ui_scale
		save_settings(app)
	}
}

// --- views ------------------------------------------------------------------

UI_SCALE_MIN :: 0.5
UI_SCALE_MAX :: 4.0
UI_SCALE_STEP :: 1.15

app_resize :: proc(app: ^App, w, h: int) {
	rl.SetWindowSize(c.int(w), c.int(h))
}

on_palette_select :: proc(cmd: Palette_Command) {
	#partial switch GuiCommand(uintptr(cmd.user_data)) {
	case .theme_rosepine:
		default_app.theme_index = 0
		save_settings(&default_app)
	case .theme_mocha:
		default_app.theme_index = 1
		save_settings(&default_app)
	case .theme_vesper:
		default_app.theme_index = 2
		save_settings(&default_app)
	case .open_results_folder:
		open_results_folder(&default_app)
	case .open_recents:
		open_recents_view(&default_app)
	case .find_files:
		results_focus_search(&default_app)
	case .refresh_plots:
		results_refresh(&default_app)
	case .toggle_left_panel:
		results_toggle_left_panel(&default_app)
	case .toggle_bottom_panel:
		results_toggle_bottom_panel(&default_app)
	case .goto_folder:
		// Keep the palette open while transitioning into the folder list.
		default_app.palette.stay_open = true
		open_folder_palette(&default_app)
	case .quit:
		default_app.running = false
	case:
		if u := uintptr(cmd.user_data); u >= FOLDER_CMD_BASE {
			results_handle_folder_select(&default_app, cmd.description)
		} else if u >= RECENT_CMD_BASE {
			results_open_folder(&default_app, cmd.description)
		}
	}
}

// --- web entry points (see gui_web/main_web.odin) -------------------------
// Thin wrappers over the default app so the `proc "c"` web callbacks have
// something to call.

init :: proc() {
	app_init(&default_app, default_config())
}

update :: proc() {
	app_update(&default_app)
}

shutdown :: proc() {
	app_shutdown(&default_app)
}

should_run :: proc() -> bool {
	return app_should_run(&default_app)
}

parent_window_size_changed :: proc(w, h: int) {
	app_resize(&default_app, w, h)
}

// --- reusable plot widgets -------------------------------------------------
// The plot procs below depend only on raylib, `Theme`, and the `draw_text` /
// `measure_text` wrappers, so they can be dropped into any raylib program.

// Margins (in ui-scale units) between a plot panel's outer rect and its data
// region: {left, top, right, bottom}.
Plot_Layout :: struct {
	left, top, right, bottom: f32,
}

// Shared, named layouts for the three plot widgets.
lineplot_margins := Plot_Layout{70, 26, 16, 22}
histogram_margins := Plot_Layout{46, 26, 12, 22}
histogram2d_margins := Plot_Layout{46, 36, 40, 22} // right side holds the colorbar

// Data region of a plot panel given its outer `rect` and named margins.
plot_area_of :: proc(rect: rl.Rectangle, m: Plot_Layout, sc: f32) -> rl.Rectangle {
	return rl.Rectangle {
		rect.x + m.left * sc,
		rect.y + m.top * sc,
		rect.width - (m.left + m.right) * sc,
		rect.height - (m.top + m.bottom) * sc,
	}
}

// Draws the horizontal x-axis label and the rotated y-axis label under/left of
// the plot area. Shared by every plot widget.
draw_plot_axis_labels :: proc(
	rect, plot_area: rl.Rectangle,
	x_label, y_label: string,
	theme: Theme,
	font_size: i32,
	sc: f32,
) {
	label_size := f32(font_size)

	x_lbl_cstr := strings.clone_to_cstring(x_label, context.temp_allocator)
	draw_text(
		x_lbl_cstr,
		i32(plot_area.x),
		i32(plot_area.y + plot_area.height + 18 * sc),
		i32(label_size),
		theme.text,
	)

	y_lbl_cstr := strings.clone_to_cstring(y_label, context.temp_allocator)
	y_ts := rl.MeasureTextEx(app_font, y_lbl_cstr, label_size, 1)
	y_pos := rl.Vector2{rect.x + 4 * sc, plot_area.y + plot_area.height * 0.5}
	y_origin := rl.Vector2{y_ts.x * 0.5, y_ts.y * 0.5}
	rl.DrawTextPro(app_font, y_lbl_cstr, y_pos, y_origin, -90, label_size, 1, theme.text)
}

// Draws a hover tooltip near `mouse`, kept inside `plot_area`, for the given
// text lines (each rendered at `font_size`). Shared by every plot widget.
draw_tooltip :: proc(
	mouse: rl.Vector2,
	plot_area: rl.Rectangle,
	lines: []string,
	theme: Theme,
	font_size: i32,
	sc: f32,
) {
	if len(lines) == 0 {
		return
	}

	fs := f32(font_size)
	cstrs := make([]cstring, len(lines), context.temp_allocator)
	max_w: f32 = 0
	line_h: f32 = 0
	for line, i in lines {
		cstrs[i] = strings.clone_to_cstring(line, context.temp_allocator)
		ts := rl.MeasureTextEx(app_font, cstrs[i], fs, 1)
		max_w = max(max_w, ts.x)
		line_h = ts.y
	}

	pad := f32(6 * sc)
	tip_w := max_w + pad * 2 + 4 * sc
	tip_h := line_h * f32(len(lines)) + pad * 2 + f32(max(0, len(lines) - 1)) * 2 + 4 * sc
	tip_x := mouse.x + 12 * sc
	if tip_x + tip_w > plot_area.x + plot_area.width {
		tip_x = mouse.x - tip_w - 12 * sc
	}
	tip_y := mouse.y - tip_h - 4 * sc
	if tip_y < plot_area.y {
		tip_y = mouse.y + 12 * sc
	}

	tip := rl.Rectangle{tip_x, tip_y, tip_w, tip_h}
	draw_shadow(tip, sc, UI_RADIUS_SM * sc)
	draw_fill_rounded(tip, theme.bg, UI_RADIUS_SM * sc)
	draw_stroke_rounded(tip, theme.border, UI_RADIUS_SM * sc, 1)
	y_off := tip_y + pad
	for cstr in cstrs {
		rl.DrawTextEx(app_font, cstr, rl.Vector2{tip_x + pad, y_off}, fs, 1, theme.text)
		y_off += line_h + 2
	}
}

PlotSeries :: struct {
	name:     string,
	color:    rl.Color,
	points:   [][2]f64,
	// Optional per-point hue values (continuous colormap coloring, seaborn
	// style); nil = solid `color`.
	hue:      []f64,
	hue_name: string,
}

// Min/max hue value across every series (ignoring NaNs). ok is false when no
// series carries hue data.
hue_domain_of :: proc(series: []PlotSeries) -> (lo, hi: f64, ok: bool) {
	lo = math.inf_f64(1)
	hi = math.inf_f64(-1)
	ok = false
	for s in series {
		if s.hue == nil {continue}
		for v in s.hue {
			if math.is_nan(v) {continue}
			lo = min(lo, v)
			hi = max(hi, v)
			ok = true
		}
	}
	if !ok {
		return 0, 1, false
	}
	if same_value(lo, hi) {
		hi = lo + 1
	}
	return lo, hi, true
}

// Continuous colormap lookup (low color -> high color) for `v` within [lo, hi].
hue_lookup :: proc(lo, hi: f64, v: f64, low_c, high_c: rl.Color) -> rl.Color {
	t := f32(clamp((v - lo) / (hi - lo), 0, 1))
	return color_lerp(low_c, high_c, t)
}

// Vertical colorbar legend for the hue colormap, drawn along the right edge of
// the plot panel (mirrors the 2D-histogram colorbar).
draw_plot_colorbar :: proc(
	rect, plot_area: rl.Rectangle,
	lo, hi: f64,
	label: string,
	theme: Theme,
	font_size: i32,
	sc: f32,
) {
	bar_x := rect.x + rect.width - 30 * sc
	bar := rl.Rectangle{bar_x, plot_area.y, 10 * sc, plot_area.height}
	for iy in 0 ..< int(bar.height) {
		t := 1 - f32(iy) / bar.height
		col := color_lerp(theme.axis_x, theme.axis_z, t)
		rl.DrawLine(
			i32(bar.x),
			i32(bar.y + f32(iy)),
			i32(bar.x + bar.width),
			i32(bar.y + f32(iy)),
			col,
		)
	}
	rl.DrawRectangleLinesEx(bar, 1, theme.border)

	top_lbl := strings.clone_to_cstring(fmt.tprintf("%.4g", hi), context.temp_allocator)
	bot_lbl := strings.clone_to_cstring(fmt.tprintf("%.4g", lo), context.temp_allocator)
	top_w := f32(measure_text(top_lbl, font_size - 2))
	bot_w := f32(measure_text(bot_lbl, font_size - 2))
	draw_text(
		top_lbl,
		i32(bar.x + bar.width * 0.5 - top_w * 0.5),
		i32(bar.y - 14 * sc),
		font_size - 2,
		theme.text,
	)
	draw_text(
		bot_lbl,
		i32(bar.x + bar.width * 0.5 - bot_w * 0.5),
		i32(bar.y + bar.height + 2 * sc),
		font_size - 2,
		theme.text,
	)

	if len(label) > 0 {
		lbl_c := strings.clone_to_cstring(label, context.temp_allocator)
		lbl_size := i32(font_size - 2)
		ts := rl.MeasureTextEx(app_font, lbl_c, f32(lbl_size), 1)
		pos := rl.Vector2{bar.x - 6 * sc, bar.y + bar.height * 0.5 + ts.x * 0.5}
		rl.DrawTextPro(app_font, lbl_c, pos, {0, 0}, -90, f32(lbl_size), 1, theme.text)
	}
}

plot_series :: proc(
	app: ^App,
	series: []PlotSeries,
	title, x_label, y_label: string,
	rect: rl.Rectangle,
	theme: Theme,
	font_size: i32,
	ui_scale: f32 = 1,
	scatter: bool = false,
) {
	sc := ui_scale
	draw_fill_rounded(rect, theme.window_bg, UI_RADIUS_SM * sc)

	title_cstr := strings.clone_to_cstring(title, context.temp_allocator)
	draw_text(title_cstr, i32(rect.x + 8 * sc), i32(rect.y + 4 * sc), i32(11 * sc), theme.muted)

	has_hue := false
	for ps in series {
		if ps.hue != nil {
			has_hue = true
			break
		}
	}
	m := lineplot_margins
	if has_hue {
		m = histogram2d_margins // right side holds the colorbar
	}
	plot_area := plot_area_of(rect, m, sc)

	if len(series) == 0 {
		draw_text("No data", i32(plot_area.x), i32(plot_area.y), i32(10 * sc), theme.text)
		return
	}

	hue_lo, hue_hi, hue_ok := f64(0), f64(1), false
	hue_label := ""
	if has_hue {
		hue_lo, hue_hi, hue_ok = hue_domain_of(series)
		for ps in series {
			if ps.hue != nil && len(ps.hue_name) > 0 {
				hue_label = ps.hue_name
				break
			}
		}
	}

	has_data := false
	x_min := math.inf_f64(1)
	x_max := math.inf_f64(-1)
	y_min := math.inf_f64(1)
	y_max := math.inf_f64(-1)

	for ps in series {
		for p in ps.points {
			has_data = true
			if p[0] < x_min {x_min = p[0]}
			if p[0] > x_max {x_max = p[0]}
			if p[1] < y_min {y_min = p[1]}
			if p[1] > y_max {y_max = p[1]}
		}
	}

	if !has_data {return}

	x_pad := (x_max - x_min) * 0.05
	y_pad := (y_max - y_min) * 0.1
	if y_min >= 0 {y_min = max(0, y_min - y_pad)} else {y_min -= y_pad}
	y_max += y_pad
	x_min -= x_pad
	x_max += x_pad
	if same_value(x_min, x_max) {x_max = x_min + 1}
	if same_value(y_min, y_max) {y_max = y_min + 1}

	x_range := x_max - x_min
	y_range := y_max - y_min

	// Grid
	for i := 0; i <= 4; i += 1 {
		t := f64(i) / 4.0
		gx := x_min + t * x_range
		gy := y_min + t * y_range
		sx := plot_area.x + f32((gx - x_min) / x_range) * plot_area.width
		sy := plot_area.y + plot_area.height - f32((gy - y_min) / y_range) * plot_area.height

		rl.DrawLine(
			i32(plot_area.x),
			i32(sy),
			i32(plot_area.x + plot_area.width),
			i32(sy),
			theme.grid,
		)
		rl.DrawLine(
			i32(sx),
			i32(plot_area.y),
			i32(sx),
			i32(plot_area.y + plot_area.height),
			theme.grid,
		)

		x_lbl := strings.clone_to_cstring(fmt.tprintf("%.2f", gx), context.temp_allocator)
		y_lbl := strings.clone_to_cstring(fmt.tprintf("%.2f", gy), context.temp_allocator)
		draw_text(
			x_lbl,
			i32(sx - 20 * sc),
			i32(plot_area.y + plot_area.height + 2 * sc),
			font_size - 2,
			theme.text,
		)
		draw_text(y_lbl, i32(plot_area.x - 60 * sc), i32(sy - 8 * sc), font_size - 2, theme.text)
	}

	// Axis labels
	draw_plot_axis_labels(rect, plot_area, x_label, y_label, theme, font_size, sc)

	// Markers / stroke thickness scale with the UI scale so dense 4K plots
	// still read (previously points/segments were hardcoded 3 px / 1 px).
	line_w := max(1.0, 1.25 * sc)
	pt_r := (3.5 if scatter else 2.25) * sc

	// Data
	for s_idx in 0 ..< len(series) {
		base_color := PLOT_COLORS[s_idx % len(PLOT_COLORS)]
		pts := series[s_idx].points
		hue := series[s_idx].hue
		if len(pts) == 0 {continue}

		if !scatter {
			// Connecting segments, each tinted by the hue of its midpoint when
			// a hue column is active.
			for i in 0 ..< len(pts) - 1 {
				x1 := plot_area.x + f32((pts[i][0] - x_min) / x_range) * plot_area.width
				y1 :=
					plot_area.y +
					plot_area.height -
					f32((pts[i][1] - y_min) / y_range) * plot_area.height
				x2 := plot_area.x + f32((pts[i + 1][0] - x_min) / x_range) * plot_area.width
				y2 :=
					plot_area.y +
					plot_area.height -
					f32((pts[i + 1][1] - y_min) / y_range) * plot_area.height
				col := base_color
				if hue != nil && hue_ok && !math.is_nan(hue[i]) && !math.is_nan(hue[i + 1]) {
					col = hue_lookup(
						hue_lo,
						hue_hi,
						(hue[i] + hue[i + 1]) * 0.5,
						theme.axis_x,
						theme.axis_z,
					)
				}
				rl.DrawLineEx(rl.Vector2{x1, y1}, rl.Vector2{x2, y2}, line_w, col)
			}
		}
		// Markers
		for p, pi in pts {
			sx := plot_area.x + f32((p[0] - x_min) / x_range) * plot_area.width
			sy := plot_area.y + plot_area.height - f32((p[1] - y_min) / y_range) * plot_area.height
			col := base_color
			if hue != nil && hue_ok && !math.is_nan(hue[pi]) {
				col = hue_lookup(hue_lo, hue_hi, hue[pi], theme.axis_x, theme.axis_z)
			}
			rl.DrawCircleV(rl.Vector2{sx, sy}, pt_r, col)
		}
	}

	// Colorbar legend
	if has_hue && hue_ok {
		draw_plot_colorbar(rect, plot_area, hue_lo, hue_hi, hue_label, theme, font_size, sc)
	}

	// Hover tooltip
	mouse := rl.GetMousePosition()
	if mouse.x >= plot_area.x &&
	   mouse.x <= plot_area.x + plot_area.width &&
	   mouse.y >= plot_area.y &&
	   mouse.y <= plot_area.y + plot_area.height {
		best_idx := -1
		best_k := -1
		best_dist := f64(math.inf_f64(1))
		best_pt: [2]f64
		for s_idx in 0 ..< len(series) {
			for p, k in series[s_idx].points {
				sx := plot_area.x + f32((p[0] - x_min) / x_range) * plot_area.width
				sy :=
					plot_area.y +
					plot_area.height -
					f32((p[1] - y_min) / y_range) * plot_area.height
				dx := f64(mouse.x - sx)
				dy := f64(mouse.y - sy)
				dist := math.sqrt(dx * dx + dy * dy)
				if dist < best_dist {
					best_dist = dist
					best_idx = s_idx
					best_k = k
					best_pt = p
				}
			}
		}
		threshold := f64(12 * sc)
		if best_idx >= 0 && best_dist < threshold {
			sx := plot_area.x + f32((best_pt[0] - x_min) / x_range) * plot_area.width
			sy :=
				plot_area.y +
				plot_area.height -
				f32((best_pt[1] - y_min) / y_range) * plot_area.height
			hover_col := PLOT_COLORS[best_idx % len(PLOT_COLORS)]
			if h := series[best_idx].hue; h != nil && hue_ok && best_k >= 0 && best_k < len(h) {
				if !math.is_nan(h[best_k]) {
					hover_col = hue_lookup(hue_lo, hue_hi, h[best_k], theme.axis_x, theme.axis_z)
				}
			}
			rl.DrawCircleLines(i32(sx), i32(sy), 6 * sc, theme.text)
			rl.DrawCircle(i32(sx), i32(sy), pt_r + 1, hover_col)

			lines := [3]string{}
			n := 0
			if len(series[best_idx].name) > 0 {
				lines[n] = series[best_idx].name
				n += 1
			}
			lines[n] = fmt.tprintf("x=%.4f  y=%.4f", best_pt[0], best_pt[1])
			n += 1
			if h := series[best_idx].hue;
			   h != nil && hue_ok && best_k >= 0 && best_k < len(h) && !math.is_nan(h[best_k]) {
				name := series[best_idx].hue_name if len(series[best_idx].hue_name) > 0 else "hue"
				lines[n] = fmt.tprintf("%s=%.4g", name, h[best_k])
				n += 1
			}
			draw_tooltip(mouse, plot_area, lines[:n], theme, font_size, sc)
		}
	}

	// Save PNG (shared widget, see plot_export.odin).
	if plot_save_button(app, rect, title, theme, sc) {
		plot_export_series(
			app,
			series,
			title,
			x_label,
			y_label,
			rect,
			theme,
			font_size,
			sc,
			scatter,
		)
	}
}

// Right side holds the colorbar when a hue column is active.
polar_margins := Plot_Layout{58, 36, 46, 30}
polar_margins_nohue := Plot_Layout{58, 26, 16, 30}

// Polar line plot. Each `PlotSeries.points[i]` is [angle (degrees), radius].
// Optional per-point `hue` colors the line/markers via a colormap + colorbar.
// Shares the panel/grid/tooltip/save style of `plot_series`.
plot_polar :: proc(
	app: ^App,
	series: []PlotSeries,
	title, angle_label, radius_label: string,
	rect: rl.Rectangle,
	theme: Theme,
	font_size: i32,
	ui_scale: f32 = 1,
) {
	sc := ui_scale
	draw_fill_rounded(rect, theme.window_bg, UI_RADIUS_SM * sc)

	title_cstr := strings.clone_to_cstring(title, context.temp_allocator)
	draw_text(title_cstr, i32(rect.x + 8 * sc), i32(rect.y + 4 * sc), i32(11 * sc), theme.muted)

	has_hue := false
	for ps in series {
		if ps.hue != nil {
			has_hue = true
			break
		}
	}
	m := polar_margins_nohue
	if has_hue {m = polar_margins}
	plot_area := plot_area_of(rect, m, sc)

	if len(series) == 0 {
		draw_text("No data", i32(plot_area.x), i32(plot_area.y), i32(10 * sc), theme.text)
		return
	}

	r_max := 0.0
	has_data := false
	for ps in series {
		for p in ps.points {
			if math.is_nan(p[0]) || math.is_nan(p[1]) {continue}
			has_data = true
			r_max = max(r_max, math.abs(p[1]))
		}
	}
	if !has_data {return}
	if r_max <= 0 {r_max = 1}

	cx := plot_area.x + plot_area.width * 0.5
	cy := plot_area.y + plot_area.height * 0.5
	radius_px := min(plot_area.width, plot_area.height) * 0.5 - 22 * sc
	if radius_px <= 1 {radius_px = 1}

	hue_lo, hue_hi, hue_ok := f64(0), f64(1), false
	hue_label := ""
	if has_hue {
		hue_lo, hue_hi, hue_ok = hue_domain_of(series)
		for ps in series {
			if ps.hue != nil && len(ps.hue_name) > 0 {
				hue_label = ps.hue_name
				break
			}
		}
	}

	// Concentric radius rings + labels.
	for i in 1 ..= 4 {
		frac := f32(i) / 4.0
		rr := radius_px * frac
		rl.DrawCircleLines(i32(cx), i32(cy), rr, theme.grid)
		lbl := strings.clone_to_cstring(fmt.tprintf("%.3g", f64(frac) * r_max), context.temp_allocator)
		tw := f32(measure_text(lbl, font_size - 2))
		draw_text(
			lbl,
			i32(cx + rr - tw * 0.5),
			i32(cy - rr - f32(font_size - 2) * 0.5),
			font_size - 2,
			theme.text,
		)
	}

	// Radial spokes every 30 degrees + angle labels (degrees) at the rim.
	// 0° = North: spokes/labels are rotated +90° from the data angle.
	for deg := 0; deg < 360; deg += 30 {
		dir := math.to_radians(f64(deg)) + math.PI / 2
		dx := f32(math.cos(dir))
		dy := f32(math.sin(dir))
		x1 := cx + dx * radius_px
		y1 := cy - dy * radius_px
		rl.DrawLine(i32(cx), i32(cy), i32(x1), i32(y1), theme.grid)

		lx := cx + dx * (radius_px + 6 * sc)
		ly := cy - dy * (radius_px + 6 * sc)
		lbl := strings.clone_to_cstring(fmt.tprintf("%.0f°", f64(deg)), context.temp_allocator)
		tw := f32(measure_text(lbl, font_size - 2))
		th := f32(font_size - 2)
		draw_text(
			lbl,
			i32(lx - tw * 0.5),
			i32(ly - th * 0.5),
			font_size - 2,
			theme.text,
		)
	}

	// Radius axis label (rotated) and angle label.
	r_lbl_c := strings.clone_to_cstring(radius_label, context.temp_allocator)
	r_ts := rl.MeasureTextEx(app_font, r_lbl_c, f32(font_size), 1)
	r_pos := rl.Vector2{rect.x + 4 * sc, cy + r_ts.y * 0.5}
	rl.DrawTextPro(app_font, r_lbl_c, r_pos, {r_ts.x * 0.5, r_ts.y * 0.5}, -90, f32(font_size), 1, theme.text)

	a_lbl_c := strings.clone_to_cstring(angle_label, context.temp_allocator)
	draw_text(
		a_lbl_c,
		i32(cx - f32(measure_text(a_lbl_c, font_size)) * 0.5),
		i32(cy + radius_px + 12 * sc),
		font_size,
		theme.text,
	)

	// Data: connecting segments (tinted by hue midpoint when active) + markers.
	line_w := max(1.0, 1.25 * sc)
	pt_r := 2.5 * sc
	project :: proc(p: [2]f64, cx, cy, radius_px: f32, r_max: f64) -> (sx, sy: f32) {
		// 0° = North (up): convert degrees to radians, then rotate by +90°.
		theta := math.to_radians(p[0]) + math.PI / 2
		r := math.abs(p[1])
		pr := f32(r / r_max) * radius_px
		return cx + pr * f32(math.cos(theta)), cy - pr * f32(math.sin(theta))
	}
	for s_idx in 0 ..< len(series) {
		base_color := PLOT_COLORS[s_idx % len(PLOT_COLORS)]
		pts := series[s_idx].points
		hue := series[s_idx].hue
		if len(pts) == 0 {continue}

		for i in 0 ..< len(pts) - 1 {
			x1, y1 := project(pts[i], cx, cy, radius_px, r_max)
			x2, y2 := project(pts[i + 1], cx, cy, radius_px, r_max)
			col := base_color
			if hue != nil && hue_ok && !math.is_nan(hue[i]) && !math.is_nan(hue[i + 1]) {
				col = hue_lookup(hue_lo, hue_hi, (hue[i] + hue[i + 1]) * 0.5, theme.axis_x, theme.axis_z)
			}
			rl.DrawLineEx(rl.Vector2{x1, y1}, rl.Vector2{x2, y2}, line_w, col)
		}
		for p, pi in pts {
			sx, sy := project(p, cx, cy, radius_px, r_max)
			col := base_color
			if hue != nil && hue_ok && !math.is_nan(hue[pi]) {
				col = hue_lookup(hue_lo, hue_hi, hue[pi], theme.axis_x, theme.axis_z)
			}
			rl.DrawCircle(i32(sx), i32(sy), pt_r, col)
		}
	}

	// Colorbar legend.
	if has_hue && hue_ok {
		draw_plot_colorbar(rect, plot_area, hue_lo, hue_hi, hue_label, theme, font_size, sc)
	}

	// Hover tooltip.
	if !app.exporting {
		mouse := rl.GetMousePosition()
		if mouse.x >= plot_area.x &&
		   mouse.x <= plot_area.x + plot_area.width &&
		   mouse.y >= plot_area.y &&
		   mouse.y <= plot_area.y + plot_area.height {
			best_idx := -1
			best_k := -1
			best_dist := f64(math.inf_f64(1))
			best_pt: [2]f64
			for s_idx in 0 ..< len(series) {
				for p, k in series[s_idx].points {
					sx, sy := project(p, cx, cy, radius_px, r_max)
					dx := f64(mouse.x - sx)
					dy := f64(mouse.y - sy)
					dist := math.sqrt(dx * dx + dy * dy)
					if dist < best_dist {
						best_dist = dist
						best_idx = s_idx
						best_k = k
						best_pt = p
					}
				}
			}
			threshold := f64(12 * sc)
			if best_idx >= 0 && best_dist < threshold {
				sx, sy := project(best_pt, cx, cy, radius_px, r_max)
				hover_col := PLOT_COLORS[best_idx % len(PLOT_COLORS)]
				if h := series[best_idx].hue; h != nil && hue_ok && best_k >= 0 && best_k < len(h) {
					if !math.is_nan(h[best_k]) {
						hover_col = hue_lookup(hue_lo, hue_hi, h[best_k], theme.axis_x, theme.axis_z)
					}
				}
				rl.DrawCircleLines(i32(sx), i32(sy), 6 * sc, theme.text)
				rl.DrawCircle(i32(sx), i32(sy), pt_r + 1, hover_col)

				lines := [3]string{}
				n := 0
				if len(series[best_idx].name) > 0 {
					lines[n] = series[best_idx].name
					n += 1
				}
				theta := best_pt[0]
				if theta >= 360.0 {theta -= 360.0}
				lines[n] = fmt.tprintf("θ=%.4f°  r=%.4f", theta, best_pt[1])
				n += 1
				if h := series[best_idx].hue;
				   h != nil && hue_ok && best_k >= 0 && best_k < len(h) && !math.is_nan(h[best_k]) {
					name := series[best_idx].hue_name if len(series[best_idx].hue_name) > 0 else "hue"
					lines[n] = fmt.tprintf("%s=%.4g", name, h[best_k])
					n += 1
				}
				draw_tooltip(mouse, plot_area, lines[:n], theme, font_size, sc)
			}
		}
	}

	// Save PNG (shared widget, see plot_export.odin).
	if plot_save_button(app, rect, title, theme, sc) {
		plot_export_polar(app, series, title, angle_label, radius_label, rect, theme, font_size, sc)
	}
}

// Freedman–Diaconis rule: bins = ceil((max-min) / (2 * IQR * n^(-1/3))).
// Data-adaptive and robust to outliers; falls back to Sturges' rule when the
// IQR is degenerate (too many tied values).
histogram_auto_bins :: proc(values: []f32) -> int {
	n_values := len(values)
	if n_values <= 1 {
		return 1
	}
	min_val := values[0]
	max_val := values[0]
	for v in values {
		min_val = min(min_val, v)
		max_val = max(max_val, v)
	}
	if max_val == min_val {
		return 1
	}

	sorted := make([]f32, n_values, context.temp_allocator)
	copy(sorted, values)
	sort.quick_sort(sorted)

	n := f32(n_values)
	q1 := sorted[n_values / 4]
	q3 := sorted[3 * n_values / 4]
	iqr := q3 - q1

	sturges := int(math.ceil(math.log2_f32(n) + 1))
	if iqr <= 0 {
		return clamp(sturges, 1, 200)
	}

	bin_width := 2 * iqr / math.cbrt_f32(n)
	if bin_width <= 0 {
		return clamp(sturges, 1, 200)
	}

	n_bins := int(math.ceil((max_val - min_val) / bin_width))
	return clamp(n_bins, 1, 200)
}

// Draws a small bin-count stepper (`- N +`) in the top-right corner of the
// histogram. `bins` is the live value (0 = auto). Mutates `bins` when the
// +/- buttons are pressed.
histogram_bin_stepper :: proc(rect: rl.Rectangle, bins: ^int, theme: Theme, sc: f32) {
	btn_size := f32(18 * sc)
	btn_y := rect.y + 2 * sc
	gap := 2 * sc

	label := fmt.tprintf("%d", bins^) if bins^ > 0 else "auto"
	label_c := strings.clone_to_cstring(label, context.temp_allocator)
	label_w := f32(measure_text(label_c, i32(11 * sc))) + 10 * sc

	total_w := btn_size * 3 + label_w + gap * 4
	right := rect.x + rect.width - 76 * sc

	minus_rect := rl.Rectangle{right - total_w, btn_y, btn_size, btn_size}
	label_rect := rl.Rectangle{minus_rect.x + minus_rect.width + gap, btn_y, label_w, btn_size}
	plus_rect := rl.Rectangle{label_rect.x + label_rect.width + gap, btn_y, btn_size, btn_size}

	draw_step_btn :: proc(r: rl.Rectangle, sym: cstring, theme: Theme, sc: f32) -> bool {
		mouse := rl.GetMousePosition()
		hover := rl.CheckCollisionPointRec(mouse, r)
		radius := 4 * sc
		draw_fill_rounded(r, theme.hover if hover else theme.bg, radius)
		draw_stroke_rounded(r, theme.border, radius, 1)
		tw := f32(measure_text(sym, i32(11 * sc)))
		draw_text(
			sym,
			i32(r.x + (r.width - tw) * 0.5),
			i32(r.y + (r.height - 11 * sc) * 0.5),
			i32(11 * sc),
			theme.text,
		)
		return hover && rl.IsMouseButtonReleased(.LEFT)
	}

	if draw_step_btn(minus_rect, "-", theme, sc) && bins^ > 0 {
		if bins^ < 2 {
			bins^ = 0
		} else {
			bins^ -= 1
		}
	}
	if draw_step_btn(plus_rect, "+", theme, sc) {
		if bins^ == 0 {
			bins^ = 2
		} else if bins^ < 200 {
			bins^ += 1
		}
	}
	draw_fill_rounded(label_rect, theme.bg, 4 * sc)
	draw_stroke_rounded(label_rect, theme.border, 4 * sc, 1)
	draw_text(
		label_c,
		i32(label_rect.x + (label_rect.width - label_w) * 0.5 + 4 * sc),
		i32(label_rect.y + (label_rect.height - 11 * sc) * 0.5),
		i32(11 * sc),
		theme.text,
	)
}

plot_histogram :: proc(
	app: ^App,
	values: []f32,
	title, x_label, y_label: string,
	number_bins: int,
	rect: rl.Rectangle,
	theme: Theme,
	font_size: i32,
	ui_scale: f32 = 1,
	bins_edit: ^int = nil,
) {
	sc := ui_scale
	draw_fill_rounded(rect, theme.window_bg, UI_RADIUS_SM * sc)

	title_cstr := strings.clone_to_cstring(title, context.temp_allocator)
	draw_text(title_cstr, i32(rect.x + 8 * sc), i32(rect.y + 4 * sc), i32(11 * sc), theme.muted)

	n_bins := number_bins
	if bins_edit != nil {
		// Skip the stepper during an offscreen PNG export so its +/- buttons can
		// never catch the click that triggered the save.
		if !app.exporting {
			histogram_bin_stepper(rect, bins_edit, theme, sc)
		}
		n_bins = bins_edit^
	}

	plot_area := plot_area_of(rect, histogram_margins, sc)

	if len(values) == 0 {
		draw_text("No data", i32(plot_area.x), i32(plot_area.y), i32(10 * sc), theme.text)
		return
	}

	min_val := values[0]
	max_val := values[0]
	for v in values {
		min_val = min(min_val, v)
		max_val = max(max_val, v)
	}

	// bin the data
	n_bars := 0
	if n_bins == 0 {
		n_bars = histogram_auto_bins(values)
	} else {
		n_bars = n_bins
	}

	if max_val == min_val {
		max_val = min_val + 1
	}
	data_range := max_val - min_val

	counts := make([]f32, n_bars, context.temp_allocator)
	for v in values {
		idx := int((v - min_val) / data_range * f32(n_bars))
		idx = clamp(idx, 0, n_bars - 1)
		counts[idx] += 1
	}

	max_count := f32(0)
	for c in counts {
		max_count = max(max_count, c)
	}
	if max_count <= 0 {max_count = 1}
	top := max_count * 1.1

	// horizontal grid + y labels
	lines := 4
	for i := 0; i <= lines; i += 1 {
		t := f32(i) / f32(lines)
		gy := top * t
		sy := plot_area.y + plot_area.height - t * plot_area.height

		rl.DrawLine(
			i32(plot_area.x),
			i32(sy),
			i32(plot_area.x + plot_area.width),
			i32(sy),
			theme.grid,
		)

		y_lbl := strings.clone_to_cstring(fmt.tprintf("%.0f", gy), context.temp_allocator)
		draw_text(y_lbl, i32(plot_area.x - 42 * sc), i32(sy - 8 * sc), font_size - 2, theme.text)
	}

	// axis labels
	draw_plot_axis_labels(rect, plot_area, x_label, y_label, theme, font_size, sc)

	// bars
	mouse := rl.GetMousePosition()
	slot := plot_area.width / f32(n_bars)
	bar_w := slot
	hover_idx := -1
	for i in 0 ..< n_bars {
		h := (counts[i] / top) * plot_area.height
		bx := plot_area.x + f32(i) * slot
		by := plot_area.y + plot_area.height - h
		bar_rect := rl.Rectangle{bx, by, bar_w, h}
		rl.DrawRectangleRec(bar_rect, theme.axis_x)
		rl.DrawRectangleLinesEx(bar_rect, 1, theme.border)

		if mouse.x >= bar_rect.x &&
		   mouse.x <= bar_rect.x + bar_rect.width &&
		   mouse.y >= plot_area.y &&
		   mouse.y <= plot_area.y + plot_area.height {
			hover_idx = i
		}
	}

	// x ticks + labels (thin out labels when there are many bars)
	axis_y := plot_area.y + plot_area.height
	tick_step := 1
	if n_bars > 8 {
		tick_step = (n_bars + 7) / 8
	}
	for i in 0 ..< n_bars {
		cx := plot_area.x + f32(i) * slot + slot * 0.5
		rl.DrawLine(i32(cx), i32(axis_y), i32(cx), i32(axis_y + 5 * sc), theme.text)
		if i % tick_step == 0 {
			// label the bin's midpoint value
			mid := min_val + (f32(i) + 0.5) * data_range / f32(n_bars)
			label_text := fmt.tprintf("%.0f", mid)
			if data_range / f32(n_bars) < 1 {
				label_text = fmt.tprintf("%.1f", mid)
			}
			lbl := strings.clone_to_cstring(label_text, context.temp_allocator)
			tw := f32(measure_text(lbl, font_size - 2))
			draw_text(lbl, i32(cx - tw * 0.5), i32(axis_y + 6 * sc), font_size - 2, theme.text)
		}
	}

	// hover tooltip
	if !app.exporting && hover_idx >= 0 {
		lo := min_val + f32(hover_idx) * data_range / f32(n_bars)
		hi := min_val + f32(hover_idx + 1) * data_range / f32(n_bars)
		line := fmt.tprintf("[%.2f, %.2f)  n=%d", lo, hi, int(counts[hover_idx]))
		draw_tooltip(mouse, plot_area, []string{line}, theme, font_size, sc)
	}

	// Save PNG (shared widget, see plot_export.odin).
	if plot_save_button(app, rect, title, theme, sc) {
		plot_export_histogram(
			app,
			values,
			title,
			x_label,
			y_label,
			n_bins,
			rect,
			theme,
			font_size,
			sc,
		)
	}
}

// 2D histogram: bins `points` on an x/y grid and renders a heatmap with a
// colorbar legend. `number_bins_x`/`number_bins_y` of 0 select Sturges' rule.
plot_histogram_2d :: proc(
	app: ^App,
	points: [][2]f64,
	title, x_label, y_label: string,
	number_bins_x, number_bins_y: int,
	rect: rl.Rectangle,
	theme: Theme,
	font_size: i32,
	ui_scale: f32 = 1,
) {
	sc := ui_scale
	draw_fill_rounded(rect, theme.window_bg, UI_RADIUS_SM * sc)

	title_cstr := strings.clone_to_cstring(title, context.temp_allocator)
	draw_text(title_cstr, i32(rect.x + 8 * sc), i32(rect.y + 4 * sc), i32(11 * sc), theme.muted)

	plot_area := plot_area_of(rect, histogram2d_margins, sc)

	if len(points) == 0 {
		draw_text("No data", i32(plot_area.x), i32(plot_area.y), i32(10 * sc), theme.text)
		return
	}

	x_vals := make([]f32, len(points), context.temp_allocator)
	y_vals := make([]f32, len(points), context.temp_allocator)
	for p, i in points {
		x_vals[i] = f32(p[0])
		y_vals[i] = f32(p[1])
	}

	n_bx := number_bins_x
	if n_bx == 0 {n_bx = histogram_auto_bins(x_vals)}
	n_by := number_bins_y
	if n_by == 0 {n_by = histogram_auto_bins(y_vals)}
	n_bx = clamp(n_bx, 1, 200)
	n_by = clamp(n_by, 1, 200)

	min_x, max_x := points[0][0], points[0][0]
	min_y, max_y := points[0][1], points[0][1]
	for p in points {
		min_x = min(min_x, p[0])
		max_x = max(max_x, p[0])
		min_y = min(min_y, p[1])
		max_y = max(max_y, p[1])
	}
	if max_x == min_x {max_x = min_x + 1}
	if max_y == min_y {max_y = min_y + 1}
	x_range := max_x - min_x
	y_range := max_y - min_y

	counts := make([]i32, n_bx * n_by, context.temp_allocator)
	for p in points {
		ix := int((p[0] - min_x) / x_range * f64(n_bx))
		iy := int((p[1] - min_y) / y_range * f64(n_by))
		ix = clamp(ix, 0, n_bx - 1)
		iy = clamp(iy, 0, n_by - 1)
		counts[iy * n_bx + ix] += 1
	}

	max_count := i32(0)
	for c in counts {max_count = max(max_count, c)}
	if max_count <= 0 {max_count = 1}

	cell_w := plot_area.width / f32(n_bx)
	cell_h := plot_area.height / f32(n_by)

	// heatmap cells (blue -> red with count), empty cells keep the background
	mouse := rl.GetMousePosition()
	hover_ix := -1
	hover_iy := 0
	hover_count := 0
	for iy in 0 ..< n_by {
		for ix in 0 ..< n_bx {
			c := counts[iy * n_bx + ix]
			if c == 0 {continue}
			cell := rl.Rectangle {
				plot_area.x + f32(ix) * cell_w,
				plot_area.y + plot_area.height - f32(iy + 1) * cell_h,
				cell_w,
				cell_h,
			}
			t := f32(c) / f32(max_count)
			col := color_lerp(theme.axis_x, theme.axis_z, t)
			rl.DrawRectangleRec(cell, col)

			if mouse.x >= cell.x &&
			   mouse.x <= cell.x + cell.width &&
			   mouse.y >= cell.y &&
			   mouse.y <= cell.y + cell.height {
				hover_ix = ix
				hover_iy = iy
				hover_count = int(c)
			}
		}
	}

	// grid lines
	for ix := 0; ix <= n_bx; ix += 1 {
		gx := plot_area.x + f32(ix) * cell_w
		rl.DrawLine(
			i32(gx),
			i32(plot_area.y),
			i32(gx),
			i32(plot_area.y + plot_area.height),
			theme.grid,
		)
	}
	for iy := 0; iy <= n_by; iy += 1 {
		gy := plot_area.y + plot_area.height - f32(iy) * cell_h
		rl.DrawLine(
			i32(plot_area.x),
			i32(gy),
			i32(plot_area.x + plot_area.width),
			i32(gy),
			theme.grid,
		)
	}

	// x ticks + labels (thin out labels when there are many bins)
	axis_y := plot_area.y + plot_area.height
	tick_step_x := 1
	if n_bx > 8 {tick_step_x = (n_bx + 7) / 8}
	for ix in 0 ..< n_bx {
		cx := plot_area.x + f32(ix) * cell_w + cell_w * 0.5
		rl.DrawLine(i32(cx), i32(axis_y), i32(cx), i32(axis_y + 5 * sc), theme.text)
		if ix % tick_step_x == 0 {
			v := min_x + f64(ix) * x_range / f64(n_bx)
			lbl := strings.clone_to_cstring(fmt.tprintf("%.1f", v), context.temp_allocator)
			tw := f32(measure_text(lbl, font_size - 2))
			draw_text(lbl, i32(cx - tw * 0.5), i32(axis_y + 6 * sc), font_size - 2, theme.text)
		}
	}
	// y ticks + labels
	axis_x := plot_area.x
	tick_step_y := 1
	if n_by > 8 {tick_step_y = (n_by + 7) / 8}
	for iy in 0 ..< n_by {
		cy := plot_area.y + plot_area.height - (f32(iy) + 0.5) * cell_h
		rl.DrawLine(i32(axis_x), i32(cy), i32(axis_x - 5 * sc), i32(cy), theme.text)
		if iy % tick_step_y == 0 {
			v := min_y + f64(iy) * y_range / f64(n_by)
			lbl := strings.clone_to_cstring(fmt.tprintf("%.1f", v), context.temp_allocator)
			tw := f32(measure_text(lbl, font_size - 2))
			draw_text(
				lbl,
				i32(axis_x - tw - 2 * sc),
				i32(cy - f32(font_size - 2) * 0.5),
				font_size - 2,
				theme.text,
			)
		}
	}

	// axis labels
	draw_plot_axis_labels(rect, plot_area, x_label, y_label, theme, font_size, sc)

	// colorbar legend
	bar_x := rect.x + rect.width - 30 * sc
	bar := rl.Rectangle{bar_x, plot_area.y, 10 * sc, plot_area.height}
	for iy in 0 ..< int(bar.height) {
		t := 1 - f32(iy) / bar.height
		col := color_lerp(theme.axis_x, theme.axis_z, t)
		rl.DrawLine(
			i32(bar.x),
			i32(bar.y + f32(iy)),
			i32(bar.x + bar.width),
			i32(bar.y + f32(iy)),
			col,
		)
	}
	rl.DrawRectangleLinesEx(bar, 1, theme.border)
	top_lbl := strings.clone_to_cstring(fmt.tprintf("%d", max_count), context.temp_allocator)
	bot_lbl := strings.clone_to_cstring(fmt.tprintf("0"), context.temp_allocator)
	top_w := f32(measure_text(top_lbl, font_size - 2))
	bot_w := f32(measure_text(bot_lbl, font_size - 2))
	draw_text(
		top_lbl,
		i32(bar.x + bar.width * 0.5 - top_w * 0.5),
		i32(bar.y - 14 * sc),
		font_size - 2,
		theme.text,
	)
	draw_text(
		bot_lbl,
		i32(bar.x + bar.width * 0.5 - bot_w * 0.5),
		i32(bar.y + bar.height + 2 * sc),
		font_size - 2,
		theme.text,
	)

	// hover tooltip
	if !app.exporting && hover_ix >= 0 {
		xlo := min_x + f64(hover_ix) * x_range / f64(n_bx)
		xhi := min_x + f64(hover_ix + 1) * x_range / f64(n_bx)
		ylo := min_y + f64(hover_iy) * y_range / f64(n_by)
		yhi := min_y + f64(hover_iy + 1) * y_range / f64(n_by)

		lines := []string {
			fmt.tprintf("x: [%.2f, %.2f)", xlo, xhi),
			fmt.tprintf("y: [%.2f, %.2f)", ylo, yhi),
			fmt.tprintf("n = %d", hover_count),
		}
		draw_tooltip(mouse, plot_area, lines, theme, font_size, sc)
	}

	// Save PNG (shared widget, see plot_export.odin).
	if plot_save_button(app, rect, title, theme, sc) {
		plot_export_histogram_2d(
			app,
			points,
			title,
			x_label,
			y_label,
			number_bins_x,
			number_bins_y,
			rect,
			theme,
			font_size,
			sc,
		)
	}
}

same_value :: #force_inline proc(a, b: f64) -> bool {
	return math.abs(a - b) <= 1e-8
}

// Linear rgba interpolation between two colors; `t` is clamped to [0, 1].
color_lerp :: proc(a, b: rl.Color, t: f32) -> rl.Color {
	u := clamp(t, 0, 1)
	return rl.Color {
		u8(f32(a.r) + (f32(b.r) - f32(a.r)) * u),
		u8(f32(a.g) + (f32(b.g) - f32(a.g)) * u),
		u8(f32(a.b) + (f32(b.b) - f32(a.b)) * u),
		u8(f32(a.a) + (f32(b.a) - f32(a.a)) * u),
	}
}
