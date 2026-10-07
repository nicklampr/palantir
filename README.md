# Palantir

Palantir is a results viewer for CSV/JSON data, with interactive 2D and 3D plots.

## CLI launch

Launch the GUI with a file and plot preselected:

```text
palantir <file_path> <plot> [options]
```

For example:

```text
palantir surface.csv contour --x x --y y --z pressure --levels 12
palantir route.csv map --lat latitude --lon longitude
palantir surface.json wireframe --x x --y y --z z
```

You can also use `--plot <name>` instead of the second positional argument.
Available plot names include `map`, `line`, `scatter`, `histogram`, `hist2d`,
`mesh`, `quiver`, `quiver3d`, `polar`, `wireframe`, and `contour`. Column options
are `--x`, `--y`, `--z`, `--u`, `--v`, `--w`, `--h`, `--lat`, and `--lon`.
Contour levels are set with `--levels N` (1–32); `--frames N` closes after N
GUI frames. For resource-release smoke tests, use `--switch-after N --then PLOT`
to switch plots automatically. Run `palantir --help` for the full option list.

The compressed Natural Earth map background is embedded in the executable.
It is decoded and uploaded only when the Map plot is opened; no external image
file is needed at runtime.
