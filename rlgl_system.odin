package palantir

// Bind only the rlgl entry points used by the app from the system raylib
// library. The current Odin vendor:raylib/rlgl package hardcodes a bundled
// Linux archive path that is absent from some raylib/Odin distributions.
foreign import raylib_lib "system:raylib"

@(default_calling_convention="c", link_prefix="rl")
foreign raylib_lib {
	PushMatrix                :: proc() ---
	PopMatrix                 :: proc() ---
	Rotatef                   :: proc(angleDeg, x, y, z: f32) ---
	EnableBackfaceCulling     :: proc() ---
	DisableBackfaceCulling    :: proc() ---
	EnableWireMode            :: proc() ---
	DisableWireMode           :: proc() ---
	DrawRenderBatchActive     :: proc() ---
}
