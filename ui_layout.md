# ui_layout.odin

A minimal egui-style, immediate-mode layout cursor for raylib drawing.

raylib has no layout system — every rectangle position and size is explicit
pixel math. `Ui` gives widgets a *linear flow* (a vertical column or a
horizontal row): you begin a cursor over a region, then allocate strips from it
and the cursor advances for you, like egui's `Ui::allocate_space`.

The layer is deliberately tiny (one struct + four procs) and has no state of
its own — you own the `Ui` value and pass it by pointer. It only depends on
`vendor:raylib` for the `rl.Vector2`/`rl.Rectangle` types.

## API

```odin
Ui_Dir :: enum { Vertical, Horizontal }

Ui :: struct {
    x, y:   f32, // origin of the next allocation
    span:   f32, // usable width (Vertical) or height (Horizontal) of the region
    cursor: f32, // offset along the flow direction, from the origin
    sc:     f32, // ui scale factor
    dir:    Ui_Dir,
}

ui_begin      :: proc(origin: rl.Vector2, span: f32, dir: Ui_Dir, sc: f32 = 1) -> Ui
ui_alloc      :: proc(u: ^Ui, size: f32, gap: f32 = 0) -> rl.Rectangle
ui_space      :: proc(u: ^Ui, size: f32)
ui_gap        :: proc(u: ^Ui, size: f32)
ui_alloc_rest :: proc(u: ^Ui) -> rl.Rectangle

Scroll_State :: struct { offset: f32, dragging: bool, grab_off: f32 }

scroll_update     :: proc(s: ^Scroll_State, content_h, viewport_h, wheel, step: f32)
scroll_thumb      :: proc(s: Scroll_State, track: rl.Rectangle, content_h, viewport_h, min_h: f32) -> (rl.Rectangle, bool)
scroll_handle_drag:: proc(s: ^Scroll_State, track, thumb: rl.Rectangle, content_h, viewport_h: f32,
                          mouse: rl.Vector2, left_pressed, left_down, left_released: bool)
draw_scrollbar    :: proc(s: Scroll_State, track: rl.Rectangle, theme: Theme, sc: f32, content_h, viewport_h: f32)
```

### Semantics

- **`ui_begin`** starts a flow at an `origin`. `span` is the usable extent
  *perpendicular* to the flow: the panel width for a `.Vertical` column, the
  panel height for a `.Horizontal` row. Pass your UI scale (`app.ui_scale`) as
  `sc` if you want strips to scale with the display.
- **`ui_alloc`** reserves a strip of `size` along the flow direction, advances
  `cursor`, and returns the strip's `rl.Rectangle`. The optional `gap` adds
  symmetric space on both sides of the strip (useful for padding between
  items).
- **`ui_space`** skips `size` of empty space (e.g. an uneven gap between two
  rows).
- **`ui_gap`** the "gaps helper": identical to `ui_space`, kept as a distinct
  name when the spacing means padding between items.
- **`ui_alloc_rest`** allocates everything remaining in `span`, i.e. a bottom
  bar / final row that fills the panel.

Nested layouts are expressed by starting a new cursor over an allocated strip.

## Scrolling

For a vertically scrollable region, keep a `Scroll_State` in your widget's
persistent state (e.g. on `App`):

```odin
// per frame, before drawing:
scroll_update(&sv, content_h, viewport_h, rl.GetMouseWheelMove(), 48 * sc)
thumb, _ := scroll_thumb(sv, track, content_h, viewport_h, 20 * sc)
scroll_handle_drag(&sv, track, thumb, content_h, viewport_h, mouse,
    rl.IsMouseButtonPressed(.LEFT), rl.IsMouseButtonDown(.LEFT), rl.IsMouseButtonReleased(.LEFT))

// while drawing, shift the cursor by the offset and clip to the viewport:
rl.BeginScissorMode(...)              // clip to the visible region
u := ui_begin(origin - {0, sv.offset}, span, .Vertical, sc)  // rows flow at scroll position
...
rl.EndScissorMode()

// after content, the themed scrollbar (no-op when content fits):
draw_scrollbar(sv, track, theme, sc, content_h, viewport_h)
```

`scroll_thumb` returns the thumb rect plus whether it is visible; the thumb is
proportional to `viewport/content` and its drag maps linearly onto the offset.

## Examples

### A vertical column

```odin
u := ui_begin(rl.Vector2{10, 10}, 200, .Vertical, sc)
r1 := ui_alloc(&u, 20)
rl.DrawText("first", i32(r1.x), i32(r1.y), 16, rl.BLACK)
r2 := ui_alloc(&u, 20)
rl.DrawText("second", i32(r2.x), i32(r2.y), 16, rl.BLACK)
// r1.y == 10, r2.y == 30; u.cursor is now 40
```

### A horizontal row of tabs

```odin
u := ui_begin(rl.Vector2{0, 0}, tab_height, .Horizontal, sc)
for v in views {
    w := f32(rl.MeasureText(v.label, 18)) + 40 * sc
    rect := ui_alloc(&u, w) // each tab sized to its label, x auto-advances
    draw_tab(rect, v.label)
}
```

### Gaps between items

```odin
u := ui_begin(rl.Vector2{0, header_h}, card_w, .Vertical, sc)
for row in 0 ..< rows {
    r := ui_alloc(&u, card_h)   // top of this row
    for col in 0 ..< cols {
        draw_card(rl.Rectangle{pad + f32(col) * (card_w + pad), r.y, card_w, card_h})
    }
    ui_space(&u, pad)           // space before the next row
}
```

### Filling the remaining space (bottom bar)

```odin
u := ui_begin(rl.Vector2{0, header_h}, sw, .Vertical, sc)
ui_alloc(&u, title_h)          // header
ui_space(&u, 8)
ui_alloc(&u, content_h)        // main content
footer := ui_alloc_rest(&u)    // everything left over
draw_status_bar(footer)
```

## Usage in this codebase

- `draw_view_tabs` — a `.Horizontal` cursor allocates each tab to its label
  width (gui.odin).
- `draw_widget_gallery` — one full-screen card per widget: a `.Vertical`
  cursor flows the rows at a scroll offset (`Scroll_State` + `ui_gap` gaps),
  clipped with scissor mode, with a draggable scrollbar.

## Caveats & tips

- **Grids are 2D, flows are 1D.** A `Ui` only advances along one axis, so for a
  multi-column grid keep the column x computed by hand and let the cursor own
  the row y (see the gallery example above).
- **Scale every pixel.** When you pass `sc` to `ui_begin`, sizes you hand to
  `ui_alloc`/`ui_space` are *not* auto-scaled — multiply them by `sc` yourself
  (`ui_alloc(&u, 20 * sc)`), matching how the rest of the codebase scales.
- **No allocation.** The cursor is a plain value; nothing is heap-allocated, so
  it is safe in the per-frame draw path (`context.temp_allocator` is untouched
  by `Ui` itself).
- **Only linear flows.** There is deliberately no flex-box/weighted layout; if
  you need proportional space, compute the sizes first and pass them in.
