import Foundation

/// Puts the `pdfsign` command on PATH and the bundled agent skill where agents look for it.
/// Shared by the app menu and `pdfsign install`.
enum Installer {
    static let commandName = "pdfsign"

    /// The real app bundle, also when this binary runs through the `pdfsign` symlink
    /// (Bundle.main then points at the symlink's directory, not the app).
    static var appBundle: Bundle {
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            if app.pathExtension == "app", let bundle = Bundle(url: app) { return bundle }
        }
        return Bundle.main
    }

    struct Result: Encodable {
        var command: String?
        /// false when the command's directory isn't on the default PATH
        var commandOnPath: Bool?
        var skills: [String] = []
        var notes: [String] = []
    }

    static func install(cli: Bool = true, skill: Bool = true) throws -> Result {
        var result = Result()
        if cli {
            let (link, onPath) = try installCommand()
            result.command = link.path
            result.commandOnPath = onPath
            if !onPath {
                result.notes.append("Add \(link.deletingLastPathComponent().path) to your PATH, e.g. in ~/.zprofile: "
                                    + "export PATH=\"$HOME/.local/bin:$PATH\"")
            }
        }
        if skill {
            result.skills = try installSkill().map(\.path)
            result.notes.append("New agent sessions pick up the skill (restart ones already running).")
        }
        return result
    }

    // MARK: Command

    /// A symlink so the command follows app updates in place. /usr/local/bin is on every
    /// shell's default PATH (/etc/paths), including agents started from GUI apps; fall back to
    /// ~/.local/bin when it isn't writable (admin-owned on some Macs).
    // TODO: offer an admin-authorized install into /usr/local/bin instead of the fallback.
    private static func installCommand() throws -> (URL, Bool) {
        guard let exe = appBundle.executableURL?.resolvingSymlinksInPath() else {
            throw AgentError("Can't locate the PDFSign executable.")
        }
        // A link into a build folder or a quarantine-translocated copy breaks once that's gone.
        guard exe.path.hasPrefix("/Applications/") || exe.path.hasPrefix(home.appendingPathComponent("Applications").path + "/")
        else {
            throw AgentError("Move PDFSign to the Applications folder first, then install the command line tool.")
        }

        let fm = FileManager.default
        let system = URL(fileURLWithPath: "/usr/local/bin")
        let dir = fm.isWritableFile(atPath: system.path) ? system : home.appendingPathComponent(".local/bin")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent(commandName)

        if fm.fileExists(atPath: link.path) || (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
            // Only replace what we put there — never someone else's `pdfsign`.
            guard let target = try? fm.destinationOfSymbolicLink(atPath: link.path),
                  URL(fileURLWithPath: target).lastPathComponent == "PDFSign" else {
                throw AgentError("\(link.path) already exists and isn't PDFSign's; remove it first.")
            }
            try fm.removeItem(at: link)
        }
        try fm.createSymbolicLink(at: link, withDestinationURL: exe)
        return (link, dir == system || pathDirectories.contains(dir.path))
    }

    /// Default login-shell PATH, not this process's (a GUI app gets a minimal one).
    private static var pathDirectories: Set<String> {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        p.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Set(path.split(separator: ":").map { (String($0) as NSString).standardizingPath })
    }

    // MARK: Skill

    /// Claude Code always; Codex and the shared ~/.agents dir when that tool is set up.
    /// Deduplicated by resolved path (~/.claude/skills is often a symlink to ~/.agents/skills).
    private static func installSkill() throws -> [URL] {
        guard let source = appBundle.url(forResource: "pdfsign", withExtension: nil) else {
            throw AgentError("The agent skill is missing from the app bundle.")
        }
        let fm = FileManager.default
        var targets = [home.appendingPathComponent(".claude/skills")]
        for tool in [".codex", ".agents"] where fm.fileExists(atPath: home.appendingPathComponent(tool).path) {
            targets.append(home.appendingPathComponent(tool).appendingPathComponent("skills"))
        }
        var seen = Set<String>(), installed: [URL] = []
        for dir in targets {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("pdfsign")
            guard seen.insert(dir.resolvingSymlinksInPath().path).inserted else { continue }
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: source, to: dest)
            installed.append(dest)
        }
        return installed
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
}
