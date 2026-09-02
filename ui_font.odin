package palantir

// Bundled app font (see fonts/Inter-Regular.ttf), embedded into the binary at
// compile time so the app renders text from any working directory (no runtime
// dependency on a fonts/ folder next to the executable). Used for every piece
// of text in the app — including raygui controls via `rl.GuiSetFont` and the
// offscreen PNG plot exports. raylib's `DrawText` and `MeasureText` always
// render with the built-in default font, so the app routes all text through
// the `draw_text`/`measure_text` wrappers below.

import "core:c"
import rl "vendor:raylib"

// The font file, pulled into the data section at build time by `#load`.
APP_FONT_DATA :: #load("fonts/Inter-Regular.ttf", []u8)
// Atlas pixel size. Text renders from ~10*sc up to ~30*sc (up to ~60 px at
// 200% UI zoom on a 4K display), so a generous base size keeps glyphs crisp.
APP_FONT_BASE_SIZE :: 96

app_font: rl.Font
app_font_loaded: bool

// Loads the embedded font. On failure (web build) the app falls back to
// raylib's built-in default font.
load_app_font :: proc() {
	app_font = rl.GetFontDefault()
	app_font_loaded = false
	when ODIN_OS != .JS {
		// LoadFontEx() auto-generates the atlas with a naive row packer whose
		// area estimate is too small for Inter at 96px: the atlas comes out
		// 1024x512 and the last row of glyphs ('y'..'~') is silently dropped.
		// Build the font manually with the skyline packer (packMethod 1) instead.
		// The #load constant isn't addressable, so copy the embedded bytes into
		// a runtime buffer for raylib to parse (it doesn't retain the buffer).
		buf := make([]u8, len(APP_FONT_DATA), context.allocator)
		defer delete(buf)
		copy(buf, APP_FONT_DATA)

		// raylib renders any codepoint missing from the atlas as '?', so load
		// the ASCII range plus the few non-ASCII glyphs the UI actually draws.
		EXTRA_GLYPHS :: [?]rune{0x00B0, 0x03B8} // ° degree, θ theta
		GLYPH_COUNT :: 95 + len(EXTRA_GLYPHS)
		codepoints: [GLYPH_COUNT]rune
		for i in 0 ..< 95 {
			codepoints[i] = rune(32 + i)
		}
		for cp, i in EXTRA_GLYPHS {
			codepoints[95 + i] = cp
		}
		glyph_count: c.int
		glyphs := rl.LoadFontData(
			&buf[0],
			c.int(len(buf)),
			APP_FONT_BASE_SIZE,
			&codepoints[0],
			GLYPH_COUNT,
			.DEFAULT,
			&glyph_count,
		)
		if glyphs != nil && glyph_count > 0 {
			recs: [^]rl.Rectangle
			atlas := rl.GenImageFontAtlas(glyphs, &recs, glyph_count, APP_FONT_BASE_SIZE, 4, 1)
			if atlas.data != nil {
				font := rl.Font {
					baseSize     = APP_FONT_BASE_SIZE,
					glyphCount   = glyph_count,
					glyphPadding = 4,
					texture      = rl.LoadTextureFromImage(atlas),
					recs         = recs,
					glyphs       = glyphs,
				}
				for i in 0 ..< glyph_count {
					rl.UnloadImage(glyphs[i].image)
					glyphs[i].image = rl.ImageFromImage(atlas, recs[i])
				}
				rl.UnloadImage(atlas)
				if font.texture.id != 0 {
					app_font = font
					app_font_loaded = true
				} else {
					rl.UnloadFont(font)
				}
			} else {
				rl.UnloadFontData(glyphs, glyph_count)
			}
		}
	}
	// Text glyphs are crisp at 1:1; bilinear needs no mipmaps (TRILINEAR would
	// warn that the atlas has none).
	rl.SetTextureFilter(app_font.texture, .BILINEAR)
}

unload_app_font :: proc() {
	if app_font_loaded {
		rl.UnloadFont(app_font)
		app_font_loaded = false
	}
}

// Equivalent of `rl.DrawText` but rendered with the app font.
draw_text :: proc(text: cstring, x, y, font_size: i32, color: rl.Color) {
	rl.DrawTextEx(app_font, text, {f32(x), f32(y)}, f32(font_size), 0, color)
}

// Equivalent of `rl.MeasureText` but measured with the app font.
measure_text :: proc(text: cstring, font_size: i32) -> i32 {
	return i32(rl.MeasureTextEx(app_font, text, f32(font_size), 0).x)
}
