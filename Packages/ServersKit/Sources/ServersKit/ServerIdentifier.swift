import Darwin
import DashCore
import Foundation

/// Identité extraite d'un process (entrée pure de `classify`, 10 · §3.4).
public struct ProcessIdentity: Sendable {
    public var execPath: String
    public var argv: [String]
    public var env: [String: String]
    public var cwd: String
    public var startTimeSec: UInt64

    public init(execPath: String, argv: [String], env: [String: String], cwd: String, startTimeSec: UInt64 = 0) {
        self.execPath = execPath
        self.argv = argv
        self.env = env
        self.cwd = cwd
        self.startTimeSec = startTimeSec
    }
}

public enum ServerIdentifier {
    // MARK: - Extraction système

    /// Lit l'identité d'un process (exec, argv, env, cwd, start time) via libproc/sysctl.
    public static func identify(pid: pid_t) -> ProcessIdentity? {
        var pathBuffer = [UInt8](repeating: 0, count: 4096)
        let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLen > 0 else { return nil }
        let execPath = String(decoding: pathBuffer[..<Int(pathLen)], as: UTF8.self)

        // cwd
        var vnodeInfo = proc_vnodepathinfo()
        var cwd = "/"
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 {
            cwd = withUnsafeBytes(of: vnodeInfo.pvi_cdir.vip_path) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
        }

        // start time
        var bsdInfo = proc_bsdinfo()
        var startTime: UInt64 = 0
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 {
            startTime = bsdInfo.pbi_start_tvsec
        }

        let (argv, env) = procArgs(pid: pid)
        return ProcessIdentity(execPath: execPath, argv: argv, env: env, cwd: cwd, startTimeSec: startTime)
    }

    /// argv + env via sysctl KERN_PROCARGS2 (10 · §3.3).
    static func procArgs(pid: pid_t) -> (argv: [String], env: [String: String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return ([], [:]) }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return ([], [:]) }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        // Après argc : exec_path\0 + padding \0* + argv[0..argc-1]\0 + env*\0.
        var index = MemoryLayout<Int32>.size
        // Sauter exec_path.
        while index < size, buffer[index] != 0 { index += 1 }
        // Sauter le padding.
        while index < size, buffer[index] == 0 { index += 1 }

        var strings: [String] = []
        var current: [UInt8] = []
        while index < size {
            if buffer[index] == 0 {
                if !current.isEmpty {
                    strings.append(String(decoding: current, as: UTF8.self))
                    current = []
                } else if strings.count >= Int(argc) {
                    break // double NUL après les env : fin
                }
            } else {
                current.append(buffer[index])
            }
            index += 1
        }
        if !current.isEmpty { strings.append(String(decoding: current, as: UTF8.self)) }

        let argv = Array(strings.prefix(Int(argc)))
        var env: [String: String] = [:]
        for entry in strings.dropFirst(Int(argc)) {
            if let eq = entry.firstIndex(of: "=") {
                env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
            }
        }
        return (argv, env)
    }

    // MARK: - Classification (pure, testable — tables 10 · §3.4)

    public struct Classification: Equatable, Sendable {
        public var framework: FrameworkKind?
        public var runtime: RuntimeKind?
        public var packageRunner: PackageRunner?
        public var script: String?
        public var displayName: String
    }

    public static func classify(_ identity: ProcessIdentity) -> Classification {
        let joined = identity.argv.joined(separator: " ")
        let basename = (identity.execPath as NSString).lastPathComponent

        let framework = detectFramework(argvJoined: joined, argv: identity.argv)
        let runtime = detectRuntime(basename: basename, execPath: identity.execPath, argvJoined: joined)
        let runner = identity.env["npm_config_user_agent"].flatMap { agent -> PackageRunner? in
            let prefix = agent.split(separator: "/").first.map(String.init) ?? ""
            return PackageRunner(rawValue: prefix)
        }
        let script = identity.env["npm_lifecycle_script"] ?? identity.env["npm_lifecycle_event"]

        let runtimeName: String? = runtime == .other ? nil : runtime.rawValue
        let displayName = framework?.rawValue ?? runtimeName ?? basename
        return Classification(framework: framework, runtime: runtime,
                              packageRunner: runner, script: script, displayName: displayName)
    }

    private static func detectFramework(argvJoined: String, argv: [String]) -> FrameworkKind? {
        func hasElement(_ name: String) -> Bool {
            argv.contains { $0 == name || $0.hasSuffix("/\(name)") }
        }
        if (hasElement("next") && (argv.contains("dev") || argv.contains("start")))
            || argvJoined.contains("next/dist/bin/next") { return .nextjs }
        if hasElement("vite") || argvJoined.contains("vite/bin/vite.js")
            || argvJoined.contains("node_modules/.bin/vite") { return .vite }
        if hasElement("astro") && (argv.contains("dev") || argv.contains("preview"))
            || argvJoined.contains("astro/astro.js") { return .astro }
        if hasElement("wrangler") && (argv.contains("dev") || argv.contains("pages")) { return .wrangler }
        if hasElement("storybook") || argvJoined.contains("storybook/bin")
            || argvJoined.contains("@storybook") { return .storybook }
        if argvJoined.contains("playwright") { return .playwright }
        // Serveurs statiques.
        let staticServers = ["serve", "http-server", "live-server", "caddy", "miniserve"]
        if staticServers.contains(where: hasElement) { return .staticServer }
        if argvJoined.contains("http.server") { return .staticServer }   // python -m http.server
        if argvJoined.contains("php -S") || (hasElement("php") && argv.contains("-S")) { return .staticServer }
        return nil
    }

    private static func detectRuntime(basename: String, execPath: String, argvJoined: String) -> RuntimeKind {
        // argv[0] est plus fiable que l'exec réel (macOS résout python3 → .../Python.app/.../Python).
        let argv0Base = (argvJoined.split(separator: " ").first.map(String.init) ?? "" as String)
        let argv0Name = (argv0Base as NSString).lastPathComponent
        if basename == "node" || argv0Name == "node" { return .node }
        if basename == "bun" || basename == "bunx" || argv0Name == "bun" { return .bun }
        if basename == "deno" || argv0Name == "deno" { return .deno }
        let pythonRegex = #"^python(\d(\.\d+)?)?$"#
        if basename.lowercased().range(of: pythonRegex, options: .regularExpression) != nil
            || argv0Name.lowercased().range(of: pythonRegex, options: .regularExpression) != nil
            || execPath.contains("/venv/bin/") || execPath.contains("Python.framework") { return .python }
        if basename == "ruby" || argv0Name == "ruby"
            || ["puma", "rails", "unicorn"].contains(where: argvJoined.contains) { return .ruby }
        if execPath.contains("/target/debug/") || execPath.contains("/target/release/") { return .rust }
        if execPath.contains("/go-build") || execPath.contains("/go/bin/") { return .go }
        return .other
    }
}
