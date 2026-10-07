package palantir

import "core:testing"

@(test)
test_cli_parse_positional_plot_and_contour_options :: proc(t: ^testing.T) {
	options, ok, error := cli_parse_args([]string {
		"surface.csv",
		"contour",
		"--x", "x",
		"--y", "y",
		"--z", "pressure",
		"--levels", "12",
		"--frames", "3",
		"--switch-after", "1",
		"--then", "scatter",
	})
	testing.expectf(t, ok, "valid CLI invocation parses: %s", error)
	testing.expect(t, options.path == "surface.csv", "first positional selects input file")
	testing.expect(t, options.plot_id == PLOT_CONTOUR, "second positional selects plot")
	testing.expect(t, options.x == "x" && options.y == "y" && options.z == "pressure", "column options parsed")
	testing.expect(t, options.levels == 12, "contour level count parsed")
	testing.expect(t, options.max_frames == 3, "frame limit parsed")
	testing.expect(t, options.switch_after == 1 && options.then_plot_id == PLOT_SCATTER, "plot-switch smoke options parsed")
}

@(test)
test_cli_parse_options_before_path :: proc(t: ^testing.T) {
	options, ok, _ := cli_parse_args([]string{"--plot", "map", "route.csv", "--lat", "lat", "--lon", "lon"})
	testing.expect(t, ok, "plot flag can precede input file")
	testing.expect(t, options.path == "route.csv" && options.plot_id == PLOT_MAP, "path and plot resolve")
	testing.expect(t, options.lat == "lat" && options.lon == "lon", "map coordinate fields parsed")
}

@(test)
test_cli_parse_rejects_invalid_levels_and_plots :: proc(t: ^testing.T) {
	_, levels_ok, _ := cli_parse_args([]string{"--levels", "0"})
	testing.expect(t, !levels_ok, "contour level count must be positive")
	_, plot_ok, _ := cli_parse_args([]string{"input.csv", "unknown_plot"})
	testing.expect(t, !plot_ok, "unknown positional plot is rejected")
}
