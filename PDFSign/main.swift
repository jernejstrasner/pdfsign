import Foundation

// One binary, two faces: known subcommands run headless (CLI / MCP server) and exit
// before any AppKit app is created; anything else launches the GUI.
if let status = CLI.runIfRequested(CommandLine.arguments) {
    exit(status)
}
PDFSignApp.main()
