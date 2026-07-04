import DashCore
import Foundation
import Testing
import TestSupport

@Suite("DashPaths")
struct DashPathsTests {
    @Test("dérivation des chemins depuis une racine injectée")
    func derivation() throws {
        let paths = try SandboxHome.create()
        #expect(paths.claudeDir.path.hasPrefix(paths.home.path))
        #expect(paths.claudeSettings.lastPathComponent == "settings.json")
        #expect(paths.cursorHooks.path.hasSuffix(".cursor/hooks.json"))
        #expect(paths.hookBinary.path.hasSuffix(".agentdash/bin/agentdash-hook"))
        #expect(paths.cursorGlobalStorageDB.path.contains("Application Support/Cursor"))
    }

    @Test("la garde anti-destruction rejette le vrai home")
    func antiDestructionGuard() {
        let real = DashPaths(home: FileManager.default.homeDirectoryForCurrentUser)
        #expect(throws: SandboxHome.SandboxError.self) {
            try SandboxHome.assertSandboxed(real)
        }
    }

    @Test("le socket reste sous la limite sun_path")
    func socketPathLength() throws {
        let paths = try SandboxHome.create()
        #expect(paths.socketPath.utf8.count < 104)
    }
}

@Suite("TestClock")
struct TestClockTests {
    @Test("advance fait avancer murale et monotone ensemble")
    func advance() {
        let clock = TestClock()
        let wall = clock.now
        clock.advance(by: 120)
        #expect(clock.now == wall.addingTimeInterval(120))
        #expect(clock.monotonicSeconds == 120)
    }

    @Test("un rollback mural ne touche pas la monotone")
    func wallClockRollback() {
        let clock = TestClock()
        clock.advance(by: 60)
        clock.setWallClock(Date(timeIntervalSince1970: 0))
        #expect(clock.monotonicSeconds == 60)
    }
}

@Suite("SessionStore")
@MainActor
struct SessionStoreTests {
    @Test("agrégation : waiting prime sur executing")
    func aggregation() {
        let store = SessionStore()
        store.replaceAll([
            SessionFixtures.make(state: .executing),
            SessionFixtures.make(state: .waiting),
            SessionFixtures.make(state: .idle),
        ])
        #expect(store.aggregateState == .waiting)
        #expect(store.liveCount == 2)
    }

    @Test("store vide : idle, zéro live")
    func empty() {
        let store = SessionStore()
        #expect(store.aggregateState == .idle)
        #expect(store.liveCount == 0)
    }
}
