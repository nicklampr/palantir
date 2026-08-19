package palantir

// Bundled app font (see fonts/Inter-Regular.ttf), loaded once at startup and
// used for every piece of text in the app — including raygui controls via
// `rl.GuiSetFont` and the offscreen PNG plot exports. raylib's `DrawText` and
// `MeasureText` always render with the built-in default font, so the app routes
// all text through the `draw_text`/`measure_text` wrappers below.

import "core:c"
import rl "vendor:raylib"

APP_FONT_PATH :: "fonts/Inter-Regular.ttf"
// Atlas pixel size. Text renders from ~10*sc up to ~30*sc (up to ~60 px at
// 200% UI zoom on a 4K display), so a generous base size keeps glyphs crisp.
APP_FONT_BASE_SIZE :: 96

app_font: rl.Font
app_font_loaded: bool

// Loads the bundled font. On failure (file missing, web build) the app falls
// back to raylib's built-in default font.
load_app_font :: proc() {
	app_font = rl.GetFontDefault()
	app_font_loaded = false
	when ODIN_OS != .JS {
		// LoadFontEx() auto-generates the atlas with a naive row packer whose
		// area estimate is too small for Inter at 96px: the atlas comes out
		// 1024x512 and the last row of glyphs ('y'..'~') is silently dropped.
		// Build the font manually with the skyline packer (packMethod 1) instead.
		GLYPH_COUNT :: 95 // ASCII 32..126
		data_size: c.int
		data := rl.LoadFileData(APP_FONT_PATH, &data_size)
		if data != nil {
			codepoints: [GLYPH_COUNT]rune
			for i in 0 ..< GLYPH_COUNT {
				codepoints[i] = rune(32 + i)
			}
			glyphs := rl.LoadFontData(
				data,
				data_size,
				APP_FONT_BASE_SIZE,
				&codepoints[0],
				GLYPH_COUNT,
				.DEFAULT,
			)
			if glyphs != nil {
				recs: [^]rl.Rectangle
				atlas := rl.GenImageFontAtlas(glyphs, &recs, GLYPH_COUNT, APP_FONT_BASE_SIZE, 4, 1)
				if atlas.data != nil {
					font := rl.Font {
						baseSize     = APP_FONT_BASE_SIZE,
						glyphCount   = GLYPH_COUNT,
						glyphPadding = 4,
						texture      = rl.LoadTextureFromImage(atlas),
						recs         = recs,
						glyphs       = glyphs,
					}
					for i in 0 ..< GLYPH_COUNT {
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
					rl.UnloadFontData(glyphs, GLYPH_COUNT)
				}
			}
			rl.UnloadFileData(data)
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
