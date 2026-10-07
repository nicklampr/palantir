package palantir

import "core:fmt"
import "core:os"

main :: proc() {
	args := os.args
	options, ok, error := cli_parse_args(args[1:])
	if !ok {
		fmt.eprintfln("Error: %s\n%s", error, CLI_USAGE)
		os.exit(2)
	}
	if options.help {
		fmt.println(CLI_USAGE)
		return
	}
	app_run_with_options(&default_app, default_config(), options)
}
