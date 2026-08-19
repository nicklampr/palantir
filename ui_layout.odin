package palantir

// A minimal egui-style immediate-mode layout cursor for raylib drawing.
//
// raylib has no layout system, so this thin layer gives widgets a linear flow
// (vertical column or horizontal row): you begin a cursor over a region, then
// `ui_alloc` a strip of a given size and the cursor advances for you. Nested
// layouts are expressed by beginning a new cursor at an allocated strip.
//
// Example (a column of two text rows):
//
//     u := ui_begin(10, 10, 200, .Vertical, sc)
//     r1 := ui_alloc(&u, 20)
//     draw_text("first", i32(r1.x), i32(r1.y), 16, rl.BLACK)
//     r2 := ui_alloc(&u, 20)
//     draw_text("second", i32(r2.x), i32(r2.y), 16, rl.BLACK)
//
// Scroll areas are the egui-style pair `ui_scroll_begin`/`ui_scroll_end`: the
// region measures its own content height as items are laid out and remembers
// it for the next frame, so the caller never computes content/viewport math.

import rl "vendor:raylib"

// Returns true while either Ctrl key is held (shared by the gallery scroll
// gate and the earth-map zoom gate).
ctrl_held :: proc() -> bool {
	return rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
}

Ui_Dir :: enum {
	Vertical,
	Horizontal,
}

Ui :: struct {
	x, y:   f32, // origin of the next allocation
	span:   f32, // usable width (Vertical) or height (Horizontal) of the region
	cursor: f32, // offset along the flow direction, from the origin
	sc:     f32, // ui scale factor
	dir:    Ui_Dir,
}

// Begin a flow layout at (x, y); `span` is the usable extent perpendicular to
// the flow direction (width for a column, height for a row).
ui_begin :: proc(x, y, span: f32, dir := Ui_Dir.Vertical, sc: f32 = 1) -> Ui {
	return Ui{x = x, y = y, span = span, dir = dir, sc = sc}
}

// Allocates a strip of `size` along the flow direction, advances past the
// strip and `gap`, and returns the strip's rect. Pass a `gap` to add spacing
// after the strip in one call.
ui_alloc :: proc(u: ^Ui, size: f32, gap: f32 = 0) -> rl.Rectangle {
	rect := rl.Rectangle{}
	switch u.dir {
	case .Vertical:
		rect = rl.Rectangle{u.x, u.y + u.cursor, u.span, size}
	case .Horizontal:
		rect = rl.Rectangle{u.x + u.cursor, u.y, size, u.span}
	}
	u.cursor += size + gap
	return rect
}

// --- scrolling -------------------------------------------------------------

// Scroll state for a vertically scrollable region. `content` holds the height
// measured by the previous `ui_scroll_end`; the scroll area uses it to clamp
// the offset and size the scrollbar (egui-style one-frame measurement lag).
Scroll_State :: struct {
	offset:   f32, // pixels scrolled up, 0 = top
	content:  f32, // content height measured last frame
	dragging: bool, // scrollbar thumb being dragged
	grab_off: f32, // mouse.y - thumb.y when the drag started
}

SCROLLBAR_GUTTER :: 14 // ui-scale units
SCROLLBAR_PAD :: 12 // ui-scale units
SCROLLBAR_MIN_THUMB :: 20
WHEEL_STEP :: 48 // ui-scale units per wheel notch

// Right-edge track the scrollbar lives in, inset by SCROLLBAR_PAD.
scroll_track :: proc(viewport: rl.Rectangle, sc: f32) -> rl.Rectangle {
	gutter := SCROLLBAR_GUTTER * sc
	pad := SCROLLBAR_PAD * sc
	return rl.Rectangle {
		x = viewport.x + viewport.width - gutter - pad,
		y = viewport.y + pad,
		width = gutter,
		height = viewport.height - 2 * pad,
	}
}

// Rect of the scrollbar thumb inside `track`, plus whether it is visible
// (hidden when the content fits the viewport). Thumb height is proportional to
// viewport/content, never smaller than `min_h`.
scroll_thumb_of :: proc(
	s: Scroll_State,
	track: rl.Rectangle,
	viewport_h, min_h: f32,
) -> (
	rl.Rectangle,
	bool,
) {
	if s.content <= viewport_h {
		return {}, false
	}
	thumb_h := max(track.height * viewport_h / s.content, min_h)
	ratio := s.offset / (s.content - viewport_h)
	thumb_y := track.y + ratio * (track.height - thumb_h)
	return rl.Rectangle{track.x, thumb_y, track.width, thumb_h}, true
}

// Begins a vertically scrollable region. `viewport` is the region to draw in
// and is also used as the scissor rect. Handles the wheel (when `wheel` is
// true) and scrollbar drag, clamped using the content height measured by the
// previous `ui_scroll_end`. Returns a Ui cursor already scrolled into place,
// with the content width (leaving room for the scrollbar). Pair with
// `ui_scroll_end`, which draws the scrollbar.
ui_scroll_begin :: proc(
	s: ^Scroll_State,
	viewport: rl.Rectangle,
	sc: f32,
	wheel: bool = true,
) -> Ui {
	max_offset := max(s.content - viewport.height, 0)
	s.offset = clamp(s.offset, 0, max_offset)

	mouse := rl.GetMousePosition()
	if wheel && rl.CheckCollisionPointRec(mouse, viewport) {
		s.offset = clamp(s.offset - rl.GetMouseWheelMove() * WHEEL_STEP * sc, 0, max_offset)
	}

	// scrollbar drag: press on the thumb starts a drag, press on the track
	// jumps the thumb to the mouse, dragging moves the offset.
	track := scroll_track(viewport, sc)
	thumb, _ := scroll_thumb_of(s^, track, viewport.height, SCROLLBAR_MIN_THUMB * sc)
	if max_offset <= 0 {
		s.dragging = false
	} else {
		if rl.IsMouseButtonPressed(.LEFT) {
			if rl.CheckCollisionPointRec(mouse, thumb) {
				s.dragging = true
				s.grab_off = mouse.y - thumb.y
			} else if rl.CheckCollisionPointRec(mouse, track) {
				s.dragging = true
				s.grab_off = thumb.height * 0.5
				s.offset =
					(mouse.y - thumb.height * 0.5 - track.y) /
					max(track.height - thumb.height, 1) *
					max_offset
			}
		}
		if s.dragging && rl.IsMouseButtonDown(.LEFT) {
			s.offset =
				(mouse.y - s.grab_off - track.y) / max(track.height - thumb.height, 1) * max_offset
		}
		if rl.IsMouseButtonReleased(.LEFT) {
			s.dragging = false
		}
		s.offset = clamp(s.offset, 0, max_offset)
	}

	pad := SCROLLBAR_PAD * sc
	gutter := SCROLLBAR_GUTTER * sc
	return Ui {
		x = viewport.x + pad,
		y = viewport.y + pad - s.offset,
		span = viewport.width - 3 * pad - gutter,
		dir = .Vertical,
		sc = sc,
	}
}

// Ends a region started with `ui_scroll_begin`: records the measured content
// height for the next frame, closes the scissor, and draws the scrollbar
// (hidden when the content fits the viewport).
ui_scroll_end :: proc(u: ^Ui, s: ^Scroll_State, viewport: rl.Rectangle, theme: Theme, sc: f32) {
	s.content = u.cursor
	rl.EndScissorMode()

	track := scroll_track(viewport, sc)
	thumb, visible := scroll_thumb_of(s^, track, viewport.height, SCROLLBAR_MIN_THUMB * sc)
	if !visible {
		return
	}
	rl.DrawRectangleRec(track, theme.bg)
	rl.DrawRectangleLinesEx(track, 1, theme.border)
	rl.DrawRectangleRec(thumb, theme.axis_x)
	rl.DrawRectangleLinesEx(thumb, 1, theme.border)
}

PLOT_BLUE :: rl.Color{31, 119, 180, 255}
PLOT_ORANGE :: rl.Color{255, 127, 14, 255}
PLOT_GREEN :: rl.Color{44, 160, 44, 255}
PLOT_RED :: rl.Color{214, 39, 40, 255}
PLOT_PURPLE :: rl.Color{148, 103, 189, 255}
PLOT_BROWN :: rl.Color{140, 86, 75, 255}

PLOT_COLORS := [?]rl.Color{PLOT_BLUE, PLOT_ORANGE, PLOT_GREEN, PLOT_RED, PLOT_PURPLE, PLOT_BROWN}

Theme :: struct {
	bg:        rl.Color,
	border:    rl.Color,
	text:      rl.Color,
	grid:      rl.Color,
	window_bg: rl.Color,
	axis_x:    rl.Color,
	axis_y:    rl.Color,
	axis_z:    rl.Color,
}

// 0 = Rosepine Dawn, 1 = Catppuccino Mocha, 2 = Vesper.
// Copied into `App.themes` at init so the app owns its palette of themes.
BASE_THEMES := [?]Theme {
	Theme { 	// Rosepine Dawn (default)
		bg        = rl.Color{0xfa, 0xf4, 0xed, 0xff},
		border    = rl.Color{0xce, 0xca, 0xcd, 0xff},
		text      = rl.Color{0x2a, 0x25, 0x40, 0xff},
		grid      = rl.Color{0xf2, 0xe9, 0xde, 0xff},
		window_bg = rl.Color{0xff, 0xfa, 0xf3, 0xff},
		axis_x    = rl.Color{0x28, 0x69, 0x83, 0xff},
		axis_y    = rl.Color{0x56, 0x94, 0x9f, 0xff},
		axis_z    = rl.Color{0xea, 0x9d, 0x34, 0xff},
	},
	Theme { 	// Catppuccino Mocha
		bg        = rl.Color{0x1e, 0x1e, 0x2e, 0xff},
		border    = rl.Color{0x58, 0x5b, 0x70, 0xff},
		text      = rl.Color{0xcd, 0xd6, 0xf4, 0xff},
		grid      = rl.Color{0x31, 0x32, 0x44, 0xff},
		window_bg = rl.Color{0x18, 0x18, 0x2b, 0xff},
		axis_x    = rl.Color{0x89, 0xb4, 0xfa, 0xff},
		axis_y    = rl.Color{0xa6, 0xe3, 0xa1, 0xff},
		axis_z    = rl.Color{0xf9, 0xe2, 0xaf, 0xff},
	},
	Theme { 	// Vesper
		bg        = rl.Color{0x10, 0x10, 0x10, 0xff},
		border    = rl.Color{0x33, 0x33, 0x33, 0xff},
		text      = rl.Color{0xed, 0xed, 0xed, 0xff},
		grid      = rl.Color{0x1c, 0x1c, 0x1c, 0xff},
		window_bg = rl.Color{0x16, 0x16, 0x16, 0xff},
		axis_x    = rl.Color{0x99, 0xff, 0xe4, 0xff},
		axis_y    = rl.Color{0xff, 0xc7, 0x99, 0xff},
		axis_z    = rl.Color{0xff, 0xff, 0xff, 0xff},
	},
}

palette_style_for_theme :: proc(t: Theme, ui_scale: f32 = 1.0) -> Palette_Style {
	s := palette_default_style()
	s.backdrop = rl.Fade(t.bg, 0.6)
	s.panel = t.window_bg
	s.border = t.border
	s.text = t.text
	s.hint = rl.Fade(t.text, 0.5)
	s.empty = rl.Fade(t.axis_z, 0.85)
	s.selection = rl.Fade(t.axis_x, 0.3)
	s.max_width *= ui_scale
	s.max_height *= ui_scale
	s.font_size = i32(f32(s.font_size) * ui_scale)
	s.row_height = i32(f32(s.row_height) * ui_scale)
	return s
}
