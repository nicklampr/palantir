package palantir

// Scrollable, modal help card opened from the command palette.

import "core:c"
import rl "vendor:raylib"

Walkthrough_Row :: struct {
	text:    cstring,
	heading: bool,
}

WALKTHROUGH_ROWS := [?]Walkthrough_Row {
	{"1. Open data", true},
	{"Use the folder path, Up button, or file browser to find CSV/JSON results.", false},
	{"Click a file to plot it; Ctrl+click selects multiple files.", false},
	{"Recents opens folders you've used before. Refresh reloads changed files.", false},
	{"Drag the dividers beside the file dock and above the table to resize them.", false},

	{"2. Navigate with the keyboard", true},
	{"Ctrl+Shift+P  Open the command palette (including this walkthrough).", false},
	{"Ctrl+F  Search files.     Ctrl+G  Browse folders in the palette.", false},
	{"Ctrl+R  Refresh.          Ctrl+L / Ctrl+B  Toggle side / bottom panels.", false},
	{"Ctrl+1..9  Switch plots (Map through Polar); use the plot menu for more.", false},
	{"Up / Down  Move through files.     Enter / Right  Open or select.", false},
	{"Left / Backspace  Go to the parent folder (outside text fields).", false},
	{"+ / -  Zoom the UI.     0  Reset the UI zoom.", false},

	{"3. Use the command palette", true},
	{"Type to filter commands; Up / Down chooses an entry, Enter runs it.", false},
	{"Tab completes the selected name. Esc goes back or closes the palette.", false},
	{"Change the theme, toggle fonts, find files, or reopen this walkthrough.", false},

	{"4. Explore plots", true},
	{"Pick a plot type and choose its data columns above the graph.", false},
	{"Hover data for details. On zoomable 2D plots: wheel zooms, middle-click resets.", false},
	{"On the map: drag to pan, Ctrl+wheel to zoom.", false},
	{"Use Save PNG on a plot to export its image to the working directory.", false},

	{"5. Move in 3D", true},
	{"Over a 3D view: WASD moves, right-drag looks, wheel changes speed.", false},
	{"E / Space rises; Q / Shift descends.", false},
}

walkthrough_row_height :: proc(row: Walkthrough_Row, sc: f32) -> f32 {
	return (34 if row.heading else 24) * sc
}

// This view is drawn instead of the explorer while open: no underlying button,
// file-browser shortcut, or plot can consume the dialog's input.
draw_walkthrough :: proc(app: ^App, theme: Theme, accept_input: bool) {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	sc := min(app.ui_scale, sw / 900, sh / 700)
	if sc <= 0 {
		return
	}
	panel_w := min(820 * sc, sw - 16)
	panel_h := min(640 * sc, sh - 16)
	if panel_w <= 0 || panel_h <= 0 {
		return
	}
	panel := rl.Rectangle{(sw - panel_w) * 0.5, (sh - panel_h) * 0.5, panel_w, panel_h}
	view := rl.Rectangle{panel.x + 24 * sc, panel.y + 78 * sc, panel_w - 48 * sc, panel_h - 124 * sc}

	rl.DrawRectangle(0, 0, c.int(sw), c.int(sh), rl.Color{0, 0, 0, 130})
	draw_panel(panel, theme, sc, true)
	draw_text("App walkthrough", c.int(panel.x + 24 * sc), c.int(panel.y + 20 * sc), i32(24 * sc), theme.text)
	close := rl.Rectangle{panel.x + panel_w - 100 * sc, panel.y + 16 * sc, 76 * sc, 32 * sc}
	clicked_close := draw_button(close, "Close", theme, sc)

	if view.width > 0 && view.height > 0 {
		content_h: f32 = 0
		for row in WALKTHROUGH_ROWS {
			content_h += walkthrough_row_height(row, sc)
		}
		max_scroll := max(content_h - view.height, 0)
		app.walkthrough_scroll = clamp(app.walkthrough_scroll, 0, max_scroll)
		if accept_input {
			if wheel := rl.GetMouseWheelMove(); wheel != 0 {
				app.walkthrough_scroll -= wheel * WHEEL_STEP * sc
			}
			if rl.IsKeyPressed(.DOWN) {app.walkthrough_scroll += 48 * sc}
			if rl.IsKeyPressed(.UP) {app.walkthrough_scroll -= 48 * sc}
			if rl.IsKeyPressed(.PAGE_DOWN) {app.walkthrough_scroll += view.height}
			if rl.IsKeyPressed(.PAGE_UP) {app.walkthrough_scroll -= view.height}
			app.walkthrough_scroll = clamp(app.walkthrough_scroll, 0, max_scroll)
		}

		rl.BeginScissorMode(c.int(view.x), c.int(view.y), c.int(view.width), c.int(view.height))
		y := view.y - app.walkthrough_scroll
		for row in WALKTHROUGH_ROWS {
			h := walkthrough_row_height(row, sc)
			if y + h > view.y && y < view.y + view.height {
				font_size := i32(f32(18 if row.heading else 15) * sc)
				color := theme.accent if row.heading else theme.text
				draw_text(row.text, c.int(view.x), c.int(y + (5 if row.heading else 3) * sc), font_size, color)
			}
			y += h
		}
		rl.EndScissorMode()
		if max_scroll > 0 {
			track := rl.Rectangle{view.x + view.width - 5 * sc, view.y, 4 * sc, view.height}
			thumb_h := max(view.height * view.height / content_h, 24 * sc)
			thumb := rl.Rectangle{
				track.x,
				track.y + app.walkthrough_scroll / max_scroll * (track.height - thumb_h),
				track.width,
				thumb_h,
			}
			draw_scrollbar(track, thumb, theme, sc)
		}
	}

	footer_y := panel.y + panel_h - 34 * sc
	draw_text("Wheel / Up-Down / PgUp-PgDn to scroll", c.int(panel.x + 24 * sc), c.int(footer_y), i32(13 * sc), theme.muted)
	if accept_input && (clicked_close || rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.ENTER)) {
		app.walkthrough_open = false
	}
}
