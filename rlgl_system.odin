package palantir

// Bind only the rlgl entry points used by the app against the raylib library
// already linked via vendor:raylib.
@(default_calling_convention="c", link_prefix="rl")
foreign _ {
	PushMatrix                :: proc() ---
	PopMatrix                 :: proc() ---
	Rotatef                   :: proc(angleDeg, x, y, z: f32) ---
	EnableBackfaceCulling     :: proc() ---
	DisableBackfaceCulling    :: proc() ---
	EnableWireMode            :: proc() ---
	DisableWireMode           :: proc() ---
	DrawRenderBatchActive     :: proc() ---
}
