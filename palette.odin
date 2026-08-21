package palantir

// A small, self-contained command-palette widget (VS Code style) with nested
// submenus.
//
// It is deliberately decoupled from the rest of the application: it owns no
// global state, does not know about windows, and only depends on `vendor:raylib`
// for input + drawing. Feed it a slice of `Palette_Command`s and an optional
// `on_select` callback and it can be reused in any raylib program.
//
// Commands with non-empty `children` open a submenu instead of running; the
// palette keeps a stack of parent layers so Esc walks back up, and only closes
// when you press Esc on the root layer. Filtering, navigation, and drawing are
// identical on every layer.
//
// Typical usage:
//
//     palette: Command_Palette
//     palette_init(&palette, my_commands[:], on_select = my_handler)
//     ...
//     // per frame:
//     palette_toggle_on_shortcut(&palette)   // Ctrl+Shift+P
//     palette_update(&palette)
//     palette_draw(&palette, screen_w, screen_h)

import "core:c"
import "core:fmt"
import rl "vendor:raylib"

// A single entry shown in the palette. `user_data` lets callers attach anything
// (an enum value, a proc pointer, an index, ...) without the palette caring.
Palette_Command :: struct {
	name:        string,
	description: string,
	user_data:   rawptr,
	// Non-empty: selecting this entry pushes a submenu (its children) instead
	// of running the command.
	children:    []Palette_Command,
}

// Called when the user activates a leaf entry (Enter / click). Return value is
// unused by the palette; wire your side effects inside the callback.
Palette_Select_Proc :: proc(cmd: Palette_Command)

// Saved state of one palette layer. The root layer lives in the palette
// struct; every nested layer is captured here when a submenu is entered.
Palette_Layer :: struct {
	commands:  []Palette_Command,
	query:     [PALETTE_QUERY_CAP]u8,
	query_len: int,
	selected:  int,
}

// Visual configuration. Zero value is invalid; use `palette_default_style()`.
Palette_Style :: struct {
	max_width:  f32,
	max_height: f32,
	top_ratio:  f32, // vertical offset of the panel as a ratio of screen height
	font_size:  i32,
	row_height: i32,
	max_rows:   int,
	backdrop:   rl.Color,
	panel:      rl.Color,
	border:     rl.Color,
	text:       rl.Color,
	hint:       rl.Color,
	empty:      rl.Color,
	selection:  rl.Color,
}

palette_default_style :: proc() -> Palette_Style {
	return Palette_Style {
		max_width = 760,
		max_height = 360,
		top_ratio = 0.2,
		font_size = 24,
		row_height = 34,
		max_rows = 8,
		backdrop = {0, 0, 0, 140},
		panel = {34, 39, 47, 245},
		border = {74, 86, 102, 255},
		text = rl.RAYWHITE,
		hint = {160, 170, 180, 255},
		empty = {182, 125, 125, 255},
		selection = {63, 72, 88, 255},
	}
}

PALETTE_QUERY_CAP :: 256

Command_Palette :: struct {
	open:          bool,
	// The root command list; `commands` points here or at a submenu's children.
	root_commands: []Palette_Command,
	commands:      []Palette_Command,
	on_select:     Palette_Select_Proc,
	style:         Palette_Style,
	query:         [PALETTE_QUERY_CAP]u8,
	query_len:     int,
	selected:      int,
	// Parent layers, most recent last. Empty at the root layer.
	layer_stack:   [dynamic]Palette_Layer,
	// scratch buffer reused every frame so filtering doesn't allocate.
	matches:       [dynamic]int,
	// When a select handler sets this, the palette stays open after the leaf is
	// activated (used to jump straight into a submenu e.g. folder navigation).
	stay_open:     bool,
	// HiDPI/4K UI scale factor; multiply pixel metrics by this when drawing.
	ui_scale:      f32,
}

// `commands` is borrowed (not copied); keep it alive for the palette's lifetime.
palette_init :: proc(
	p: ^Command_Palette,
	commands: []Palette_Command,
	on_select: Palette_Select_Proc = nil,
	style: Palette_Style = {},
	allocator := context.allocator,
) {
	p.root_commands = commands
	p.commands = commands
	p.on_select = on_select
	p.style = style if style.font_size != 0 else palette_default_style()
	p.ui_scale = 1.0
	p.layer_stack = make([dynamic]Palette_Layer, allocator)
	p.matches = make([dynamic]int, allocator)
	palette_reset(p)
}

palette_destroy :: proc(p: ^Command_Palette) {
	delete(p.layer_stack)
	delete(p.matches)
}

palette_reset :: proc(p: ^Command_Palette) {
	p.query_len = 0
	p.selected = 0
	clear(&p.matches)
}

palette_open_it :: proc(p: ^Command_Palette) {
	p.open = true
	clear(&p.layer_stack)
	p.commands = p.root_commands
	palette_reset(p)
}

palette_close :: proc(p: ^Command_Palette) {
	p.open = false
}

palette_toggle :: proc(p: ^Command_Palette) {
	if p.open {
		palette_close(p)
	} else {
		palette_open_it(p)
	}
}

// Opens/closes the palette when Ctrl+Shift+P is pressed. Returns true if toggled.
palette_toggle_on_shortcut :: proc(p: ^Command_Palette) -> bool {
	if rl.IsKeyPressed(.P) {
		ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
		shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
		if ctrl && shift {
			palette_toggle(p)
			return true
		}
	}
	return false
}

// Consumes keyboard input while open (typing, navigation, Enter, Esc).
// No-op when the palette is closed.
palette_update :: proc(p: ^Command_Palette) {
	if !p.open {
		return
	}

	if rl.IsKeyPressed(.ESCAPE) {
		if len(p.layer_stack) > 0 {
			palette_pop_layer(p)
		} else {
			palette_close(p)
		}
		return
	}

	for {
		ch := rl.GetCharPressed()
		if ch == 0 {
			break
		}
		if ch >= 32 && ch <= 126 && p.query_len < len(p.query) {
			p.query[p.query_len] = u8(ch)
			p.query_len += 1
		}
	}

	if rl.IsKeyPressed(.BACKSPACE) && p.query_len > 0 {
		p.query_len -= 1
		p.query[p.query_len] = 0
	}

	palette_refresh_matches(p)
	n := len(p.matches)

	if n > 0 {
		if rl.IsKeyPressed(.DOWN) {
			p.selected = (p.selected + 1) % n
		}
		if rl.IsKeyPressed(.UP) {
			p.selected = (p.selected - 1 + n) % n
		}
	}
	p.selected = clamp(p.selected, 0, max(0, n - 1))

	// Tab autocompletes the query to the currently selected entry's name
	// (used in the folder-navigation palette and every submenu).
	if rl.IsKeyPressed(.TAB) && n > 0 {
		palette_complete_selected(p)
	}

	if rl.IsKeyPressed(.ENTER) && n > 0 {
		palette_activate(p, p.matches[p.selected])
	}
}

// Replaces the palette query with the selected entry's name and re-filters.
// Lets Tab complete e.g. a partial folder name in the Ctrl+G folder view.
palette_complete_selected :: proc(p: ^Command_Palette) {
	if len(p.matches) == 0 {
		return
	}
	selected := clamp(p.selected, 0, len(p.matches) - 1)
	cmd := p.commands[p.matches[selected]]
	if len(cmd.name) == 0 || len(cmd.name) > PALETTE_QUERY_CAP {
		return
	}
	for i in 0 ..< len(cmd.name) {
		p.query[i] = cmd.name[i]
	}
	p.query_len = len(cmd.name)
	palette_refresh_matches(p)
}

// Activates the selected entry. Commands with children push a submenu layer;
// leaves run the callback and close the palette.
palette_activate :: proc(p: ^Command_Palette, command_index: int) {
	cmd := p.commands[command_index]
	if len(cmd.children) > 0 {
		palette_push_layer(p)
		p.commands = cmd.children
		palette_reset(p)
		return
	}
	if p.on_select != nil {
		p.on_select(cmd)
	}
	if !p.stay_open {
		palette_close(p)
	}
	p.stay_open = false
}

// Captures the current layer so Esc can return to it.
palette_push_layer :: proc(p: ^Command_Palette) {
	append(
		&p.layer_stack,
		Palette_Layer {
			commands = p.commands,
			query = p.query,
			query_len = p.query_len,
			selected = p.selected,
		},
	)
}

// Restores the previous layer's commands, query, and selection.
palette_pop_layer :: proc(p: ^Command_Palette) {
	layer := pop(&p.layer_stack)
	p.commands = layer.commands
	p.query = layer.query
	p.query_len = layer.query_len
	p.selected = layer.selected
	palette_refresh_matches(p)
}

palette_query_string :: proc(p: ^Command_Palette) -> string {
	return string(p.query[:p.query_len])
}

// Recomputes `p.matches` (indices into `p.commands`) for the current query.
// With an empty query every command matches, preserving declaration order.
palette_refresh_matches :: proc(p: ^Command_Palette) {
	clear(&p.matches)
	query := palette_query_string(p)
	for cmd, i in p.commands {
		if palette_fuzzy_contains(cmd.name, query) ||
		   palette_fuzzy_contains(cmd.description, query) {
			append(&p.matches, i)
		}
	}
}

palette_draw :: proc(p: ^Command_Palette, screen_w, screen_h: f32) {
	if !p.open {
		return
	}

	s := p.style
	sc := p.ui_scale
	rl.DrawRectangle(0, 0, c.int(screen_w), c.int(screen_h), s.backdrop)

	panel_w := min(s.max_width, screen_w - 32 * sc)
	panel_h := min(s.max_height, screen_h - 32 * sc)
	panel_x := (screen_w - panel_w) * 0.5
	panel_y := screen_h * s.top_ratio

	panel := rl.Rectangle{panel_x, panel_y, panel_w, panel_h}
	rl.DrawRectangleRec(panel, s.panel)
	rl.DrawRectangleLinesEx(panel, 2, s.border)

	input := fmt.ctprintf("> %s", palette_query_string(p))
	draw_text(input, c.int(panel_x + 18 * sc), c.int(panel_y + 14 * sc), s.font_size, s.text)
	rl.DrawLine(
		c.int(panel_x + 16 * sc),
		c.int(panel_y + 48 * sc),
		c.int(panel_x + panel_w - 16 * sc),
		c.int(panel_y + 48 * sc),
		s.border,
	)

	list_y := int(panel_y + 64 * sc)
	visible := min(s.max_rows, len(p.matches))

	for i in 0 ..< visible {
		cmd := p.commands[p.matches[i]]
		row_y := list_y + i * int(s.row_height)

		if i == p.selected {
			rl.DrawRectangle(
				c.int(panel_x + 10 * sc),
				c.int(f32(row_y) - 4 * sc),
				c.int(panel_w - 20 * sc),
				s.row_height,
				s.selection,
			)
		}

		suffix := " >" if len(cmd.children) > 0 else ""
		label := fmt.ctprintf("%s%s - %s", cmd.name, suffix, cmd.description)
		draw_text(label, c.int(panel_x + 20 * sc), c.int(row_y), s.font_size - 4, s.text)
	}

	if len(p.matches) == 0 {
		draw_text(
			"No command found",
			c.int(panel_x + 20 * sc),
			c.int(list_y),
			s.font_size - 4,
			s.empty,
		)
	}

	esc_hint := "Esc to close"
	if len(p.layer_stack) > 0 {
		esc_hint = "Esc to go back"
	}
	draw_text(
		fmt.ctprintf("Enter to run, %s", esc_hint),
		c.int(panel_x + 18 * sc),
		c.int(panel_y + panel_h - 30 * sc),
		i32(16 * sc),
		s.hint,
	)
}

// Case-insensitive substring search (ASCII). Empty needle always matches.
palette_fuzzy_contains :: proc(haystack, needle: string) -> bool {
	if len(needle) == 0 {
		return true
	}
	if len(needle) > len(haystack) {
		return false
	}

	for i in 0 ..= len(haystack) - len(needle) {
		match := true
		for j in 0 ..< len(needle) {
			if ascii_to_lower(haystack[i + j]) != ascii_to_lower(needle[j]) {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}

ascii_to_lower :: proc(ch: u8) -> u8 {
	return ch + 32 if ch >= 'A' && ch <= 'Z' else ch
}
