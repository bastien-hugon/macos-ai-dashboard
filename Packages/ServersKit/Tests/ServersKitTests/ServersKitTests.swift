import DashCore
import Foundation
import Testing
@testable import ServersKit

@Suite("ServerIdentifier.classify (10 · §3.4)")
struct ClassifyTests {
    private func identity(exec: String, argv: [String], env: [String: String] = [:]) -> ProcessIdentity {
        ProcessIdentity(execPath: exec, argv: argv, env: env, cwd: "/tmp/proj")
    }

    @Test("frameworks : Next.js, Vite, Astro, Wrangler, Storybook, Playwright, statique")
    func frameworks() {
        #expect(ServerIdentifier.classify(identity(
            exec: "/usr/local/bin/node",
            argv: ["node", "/p/node_modules/next/dist/bin/next", "dev"]
        )).framework == .nextjs)
        #expect(ServerIdentifier.classify(identity(
            exec: "/usr/local/bin/node",
            argv: ["node", "/p/node_modules/.bin/vite"]
        )).framework == .vite)
        #expect(ServerIdentifier.classify(identity(
            exec: "/usr/local/bin/node", argv: ["node", "astro", "dev"]
        )).framework == .astro)
        #expect(ServerIdentifier.classify(identity(
            exec: "/usr/local/bin/node", argv: ["node", "wrangler", "dev"]
        )).framework == .wrangler)
        #expect(ServerIdentifier.classify(identity(
            exec: "/usr/local/bin/node", argv: ["node", "/p/@storybook/cli/bin/index.js"]
        )).framework == .storybook)
        #expect(ServerIdentifier.classify(identity(
            exec: "/usr/local/bin/node", argv: ["node", "playwright", "show-report"]
        )).framework == .playwright)
        #expect(ServerIdentifier.classify(identity(
            exec: "/usr/bin/python3", argv: ["python3", "-m", "http.server", "8123"]
        )).framework == .staticServer)
    }

    @Test("runtimes : node, bun, deno, python, ruby, rust, go")
    func runtimes() {
        func runtime(_ exec: String, _ argv: [String] = []) -> RuntimeKind? {
            ServerIdentifier.classify(identity(exec: exec, argv: argv)).runtime
        }
        #expect(runtime("/opt/homebrew/bin/node") == .node)
        #expect(runtime("/opt/homebrew/bin/bun") == .bun)
        #expect(runtime("/opt/homebrew/bin/deno") == .deno)
        #expect(runtime("/usr/bin/python3.12") == .python)
        #expect(runtime("/usr/bin/ruby") == .ruby)
        #expect(runtime("/p/target/debug/myserver") == .rust)
        #expect(runtime("/Users/x/go/bin/api") == .go)
        #expect(runtime("/usr/local/bin/whatever") == RuntimeKind.other)
    }

    @Test("package runner depuis npm_config_user_agent, script depuis lifecycle")
    func runnerAndScript() {
        let c = ServerIdentifier.classify(identity(
            exec: "/opt/homebrew/bin/node",
            argv: ["node", "server.js"],
            env: [
                "npm_config_user_agent": "pnpm/9.15.0 npm/? node/v22.18.0 darwin arm64",
                "npm_lifecycle_script": "next dev --turbo",
            ]
        ))
        #expect(c.packageRunner == .pnpm)
        #expect(c.script == "next dev --turbo")
    }

    @Test("displayName : framework > runtime > basename")
    func displayName() {
        #expect(ServerIdentifier.classify(identity(
            exec: "/opt/homebrew/bin/node", argv: ["node", "vite"]
        )).displayName == "Vite")
        #expect(ServerIdentifier.classify(identity(
            exec: "/opt/homebrew/bin/node", argv: ["node", "server.js"]
        )).displayName == "Node")
        #expect(ServerIdentifier.classify(identity(
            exec: "/usr/local/bin/customd", argv: ["customd"]
        )).displayName == "customd")
    }
}

@Suite("ServerStopper — garde-fous (10 · §3.5)")
struct StopperGuardTests {
    @Test("PID système et soi-même refusés")
    func refusals() {
        #expect(ServerStopper.validate(pid: 1, expectedStartTimeSec: 0, expectedExecPath: "/sbin/launchd") != nil)
        #expect(ServerStopper.validate(pid: getpid(), expectedStartTimeSec: 0, expectedExecPath: "") != nil)
    }

    @Test("start time incohérent (PID réutilisé) refusé")
    func startTimeMismatch() {
        // Notre propre process a un start time réel ≠ 12345.
        let reason = ServerStopper.validate(pid: getpid(), expectedStartTimeSec: 12345, expectedExecPath: "/x")
        #expect(reason != nil)
    }
}

@Suite("Scan réel de bout en bout")
struct LiveScanTests {
    @Test("un http.server Python sur un port de la plage est détecté, identifié, puis stoppé")
    func detectRealServer() async throws {
        let port: UInt16 = 8471
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        // Attendre que le serveur écoute réellement (polling jusqu'à 3 s).
        var found: DevServer?
        for _ in 0..<15 {
            try await Task.sleep(for: .milliseconds(200))
            if let hit = ServerBuilder.build().first(where: { $0.id.port == port }) {
                found = hit
                break
            }
        }
        #expect(found != nil, "le serveur de test doit être détecté")
        if let found {
            #expect(found.runtime == .python)
            #expect(found.framework == .staticServer)
            #expect(found.id.pid == process.processIdentifier)
            #expect(found.startTimeSec > 0)

            // Arrêt sécurisé de bout en bout.
            let outcome = await ServerStopper.stop(
                pid: found.id.pid, startTimeSec: found.startTimeSec, execPath: found.execPath
            )
            #expect(outcome == .terminated || outcome == .alreadyGone)
            #expect(!process.isRunning)
        }
    }
}
