package palantir

import "core:fmt"
import "core:strconv"
import "core:strings"

CLI_Options :: struct {
	path:           string,
	plot_id:        int,
	x, y, z, h:     string,
	u, v, w:        string,
	lat, lon:       string,
	levels:         int,
	bins:           int,
	max_frames:     int, // 0 = run until the window is closed
	switch_after:   int, // optional plot-switch smoke test
	then_plot_id:   int,
	help:           bool,
}

CLI_USAGE :: `Palantir - result plot viewer

Usage:
  palantir [FILE] [PLOT] [OPTIONS]
  palantir --plot PLOT [OPTIONS] [FILE]

Plots: map, line, scatter, histogram, hist2d, mesh, quiver, quiver3d,
       polar, wireframe, contour

Options:
  --plot NAME       Select a plot (also accepted as the second positional argument)
  --x COLUMN        X field/column
  --y COLUMN        Y field/column
  --z COLUMN        Z field/column
  --u COLUMN        U vector component
  --v COLUMN        V vector component
  --w COLUMN        W vector component
  --h COLUMN        Hue/color column
  --lat COLUMN      Latitude column for maps
  --lon COLUMN      Longitude column for maps
  --levels N        Number of contour levels (1..32)
  --bins N          Histogram bins
  --frames N        Close after N GUI frames (useful for smoke tests)
  --switch-after N  Switch to --then after N frames (smoke-test resource release)
  --then PLOT       Plot to switch to when --switch-after is reached
  -h, --help        Show this help

Examples:
  palantir results.csv contour --x x --y y --z pressure --levels 12
  palantir route.csv map --lat latitude --lon longitude
  palantir surface.json wireframe --x x --y y --z z
  palantir route.csv map --lat lat --lon lon --frames 1
  palantir route.csv map --switch-after 2 --then scatter --frames 3
`

cli_plot_id :: proc(name: string) -> (id: int, ok: bool) {
	lower := strings.to_lower(name, context.temp_allocator)
	switch lower {
	case "map":
		return PLOT_MAP, true
	case "line":
		return PLOT_LINE, true
	case "scatter":
		return PLOT_SCATTER, true
	case "hist", "histogram":
		return PLOT_HIST, true
	case "hist2d", "2d", "2d-histogram", "histogram2d":
		return PLOT_HIST2D, true
	case "mesh", "mesh3d":
		return PLOT_MESH3D, true
	case "quiver":
		return PLOT_QUIVER, true
	case "quiver3d", "3d-quiver":
		return PLOT_QUIVER3D, true
	case "polar":
		return PLOT_POLAR, true
	case "wireframe", "wireframe3d", "3d-wireframe":
		return PLOT_WIREFRAME3D, true
	case "contour":
		return PLOT_CONTOUR, true
	case:
		return -1, false
	}
}

cli_parse_args :: proc(args: []string) -> (options: CLI_Options, ok: bool, error: string) {
	options.plot_id = -1
	options.then_plot_id = -1
	options.levels = CONTOUR_LEVEL_COUNT
	options.bins = 0

	positional_count := 0
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if arg == "-h" || arg == "--help" {
			options.help = true
			continue
		}
		if strings.has_prefix(arg, "--") {
			if i + 1 >= len(args) {
				return options, false, fmt.tprintf("missing value after %s", arg)
			}
			value := args[i + 1]
			switch arg {
			case "--plot":
				id, id_ok := cli_plot_id(value)
				if !id_ok {return options, false, fmt.tprintf("unknown plot: %s", value)}
				options.plot_id = id
			case "--x": options.x = value
			case "--y": options.y = value
			case "--z": options.z = value
			case "--u": options.u = value
			case "--v": options.v = value
			case "--w": options.w = value
			case "--h", "--color": options.h = value
			case "--lat": options.lat = value
			case "--lon": options.lon = value
			case "--levels":
				n, n_ok := strconv.parse_int(value)
				if !n_ok || n < CONTOUR_LEVEL_MIN || n > CONTOUR_LEVEL_MAX {
					return options, false, "--levels must be between 1 and 32"
				}
				options.levels = n
			case "--bins":
				n, n_ok := strconv.parse_int(value)
				if !n_ok || n < 1 || n > 100_000 {
					return options, false, "--bins must be between 1 and 100000"
				}
				options.bins = n
			case "--frames":
				n, n_ok := strconv.parse_int(value)
				if !n_ok || n < 1 {
					return options, false, "--frames must be a positive integer"
				}
				options.max_frames = n
			case "--switch-after":
				n, n_ok := strconv.parse_int(value)
				if !n_ok || n < 1 {
					return options, false, "--switch-after must be a positive integer"
				}
				options.switch_after = n
			case "--then":
				id, id_ok := cli_plot_id(value)
				if !id_ok {return options, false, fmt.tprintf("unknown plot: %s", value)}
				options.then_plot_id = id
			case:
				return options, false, fmt.tprintf("unknown option: %s", arg)
			}
			i += 1
			continue
		}

		positional_count += 1
		switch positional_count {
		case 1:
			options.path = arg
		case 2:
			if options.plot_id >= 0 {
				return options, false, "plot specified more than once"
			}
			id, id_ok := cli_plot_id(arg)
			if !id_ok {return options, false, fmt.tprintf("unknown plot: %s", arg)}
			options.plot_id = id
		case:
			return options, false, "too many positional arguments"
		}
	}
	if options.switch_after > 0 && options.then_plot_id < 0 {
		return options, false, "--switch-after requires --then PLOT"
	}
	if options.then_plot_id >= 0 && options.switch_after == 0 {
		return options, false, "--then requires --switch-after N"
	}
	if options.switch_after > 0 && options.max_frames > 0 && options.max_frames <= options.switch_after {
		return options, false, "--frames must exceed --switch-after so the second plot can render"
	}
	return options, true, ""
}

cli_apply_options :: proc(app: ^App, options: CLI_Options) {
	rs := &app.results
	if options.path != "" {
		results_open_path(app, options.path)
	}
	if options.plot_id >= 0 {
		rs.plot.id = options.plot_id
	}
	if options.levels > 0 {
		rs.plot.contour_levels = clamp(options.levels, CONTOUR_LEVEL_MIN, CONTOUR_LEVEL_MAX)
	}
	if options.bins > 0 {
		rs.plot.bins = options.bins
	}
	if ds := active_dataset(rs); ds != nil {
		if options.x != "" {rs.plot.x_col = results_col_index(ds, options.x)}
		if options.y != "" {rs.plot.y_col = results_col_index(ds, options.y)}
		if options.z != "" {rs.plot.z_col = results_col_index(ds, options.z)}
		if options.h != "" {rs.plot.h_col = results_col_index(ds, options.h)}
		if options.u != "" {rs.plot.u_col = results_col_index(ds, options.u)}
		if options.v != "" {rs.plot.v_col = results_col_index(ds, options.v)}
		if options.w != "" {rs.plot.w_col = results_col_index(ds, options.w)}
		if options.lat != "" {rs.plot.lat_col = results_col_index(ds, options.lat)}
		if options.lon != "" {rs.plot.lon_col = results_col_index(ds, options.lon)}
	}
}
