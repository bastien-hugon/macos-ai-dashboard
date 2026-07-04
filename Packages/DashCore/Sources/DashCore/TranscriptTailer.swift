import CoreServices
import Foundation

/// Surveillance FSEvents récursive d'un arbre de fichiers (03 · REQ-CLA-20, 01 · §5.1).
/// Générique : signale des chemins modifiés (filtrés par suffixe) sur une queue dédiée ;
/// la lecture incrémentale par offsets appartient à l'ingesteur (actor du provider).
/// Ne raisonne jamais sur les flags FSEvents : l'ingesteur `stat()` puis relit.
public final class TranscriptTailer: @unchecked Sendable {
    public typealias Handler = @Sendable ([String]) -> Void

    private let roots: [String]
    private let pathSuffix: String?
    private let latency: CFTimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.agentdash.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?

    /// - Parameters:
    ///   - roots: dossiers racines à surveiller (créés s'ils n'existent pas encore, pour
    ///     que le watch prenne effet dès la création par l'agent).
    ///   - pathSuffix: filtre de suffixe (ex. ".jsonl") ; nil = tous les fichiers.
    public init(roots: [URL], pathSuffix: String?, latency: CFTimeInterval = 0.3, handler: @escaping Handler) {
        self.roots = roots.map(\.path)
        self.pathSuffix = pathSuffix
        self.latency = latency
        self.handler = handler
    }

    deinit { stop() }

    public func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let tailer = Unmanaged<TranscriptTailer>.fromOpaque(info).takeUnretainedValue()
            guard let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
                as? [String] else { return }
            tailer.dispatch(paths: Array(paths.prefix(count)))
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            )
        ) else {
            DashLog.claude.error("FSEventStreamCreate a échoué")
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func dispatch(paths: [String]) {
        var matched = paths
        if let pathSuffix {
            // Filtre strict du suffixe : ignore les temporaires d'écriture atomique
            // (.sb-*, REQ-CLA-20). Un événement de dossier déclenche un re-scan ciblé
            // côté ingesteur via le chemin du dossier.
            matched = paths.filter { $0.hasSuffix(pathSuffix) || !$0.contains(".") }
        }
        guard !matched.isEmpty else { return }
        handler(Array(Set(matched)))
    }
}
