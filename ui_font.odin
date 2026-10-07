package palantir

// Bundled app font (see fonts/Inter-Regular.ttf), embedded into the binary at
// compile time so it is available from any working directory. The active font
// can be switched between this font and raylib's built-in default via the
// command palette. Every UI and plot-export text path uses the active font.

import "core:c"
import rl "vendor:raylib"

// The font file, pulled into the data section at build time by `#load`.
APP_FONT_DATA :: #load("fonts/Inter-Regular.ttf", []u8)
// Atlas pixel size. Text renders from ~10*sc up to ~30*sc (up to ~60 px at
// 200% UI zoom on a 4K display), so a generous base size keeps glyphs crisp.
APP_FONT_BASE_SIZE :: 96

app_font: rl.Font // active font used by all drawing and measuring wrappers
app_custom_font: rl.Font
app_font_loaded: bool // custom font atlas was loaded successfully
app_font_is_default: bool

// Loads the embedded font. On failure (web build) the app falls back to
// raylib's built-in default font.
load_app_font :: proc() {
	app_font = rl.GetFontDefault()
	// The built-in font is a low-resolution bitmap atlas. Keep it on nearest-
	// neighbor sampling even when the custom font is the currently active one.
	rl.SetTextureFilter(app_font.texture, .POINT)
	app_custom_font = rl.GetFontDefault()
	app_font_loaded = false
	app_font_is_default = true
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
					app_custom_font = font
					app_font = font
					app_font_loaded = true
					app_font_is_default = false
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
	if app_font_loaded {
		rl.SetTextureFilter(app_custom_font.texture, .BILINEAR)
	}
}

// Toggles between the custom bundled font and raylib's built-in default.
// Returns false when the custom font could not be loaded (e.g. on web).
toggle_app_font :: proc() -> bool {
	if !app_font_loaded {
		return false
	}
	app_font_is_default = !app_font_is_default
	if app_font_is_default {
		app_font = rl.GetFontDefault()
		// The built-in atlas is low-resolution bitmap art; linear filtering
		// smears its glyphs when the UI scales it above the native size.
		rl.SetTextureFilter(app_font.texture, .POINT)
	} else {
		app_font = app_custom_font
	}
	rl.GuiSetFont(app_font)
	return true
}

unload_app_font :: proc() {
	if app_font_loaded {
		rl.UnloadFont(app_custom_font)
		app_custom_font = {}
		app_font_loaded = false
	}
	app_font = rl.GetFontDefault()
	app_font_is_default = true
}

// Equivalent of `rl.DrawText` but rendered with the app font.
draw_text :: proc(text: cstring, x, y, font_size: i32, color: rl.Color) {
	rl.DrawTextEx(app_font, text, {f32(x), f32(y)}, f32(font_size), 0, color)
}

// Equivalent of `rl.MeasureText` but measured with the app font.
measure_text :: proc(text: cstring, font_size: i32) -> i32 {
	return i32(rl.MeasureTextEx(app_font, text, f32(font_size), 0).x)
}
