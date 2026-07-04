import DashCore
import SwiftUI

/// Avatar pixel-grid 5×5 (05 · REQ-NUI-52..54, spécification canonique 07 · §3.3) :
/// identicon stable dérivé de la graine (symétrie verticale), animé selon l'état —
/// vague diagonale (`executing` 1,2 Hz, `thinking` 0,5 Hz amplitude réduite),
/// rotation calme de lumière (`waiting`), statique atténué (`idle`/`ended`).
public struct PixelAvatarView: View {
    public let seed: UInt64
    public let state: SessionState
    public let paused: Bool
    public let sideLength: CGFloat
    public let framesPerSecond: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        seed: UInt64,
        state: SessionState,
        paused: Bool = false,
        sideLength: CGFloat = 24,
        framesPerSecond: Double = 20
    ) {
        self.seed = seed
        self.state = state
        self.paused = paused
        self.sideLength = sideLength
        self.framesPerSecond = framesPerSecond
    }

    private var isStatic: Bool {
        paused || reduceMotion || state == .idle || state == .ended
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1 / framesPerSecond, paused: isStatic)) { timeline in
            Canvas { context, size in
                draw(in: &context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(width: sideLength, height: sideLength)
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let grid = Self.pattern(seed: seed)
        let cell = size.width / 5
        let inset = cell * 0.12
        let tint = state.tint

        for row in 0..<5 {
            for col in 0..<5 where grid[row][col] {
                let rect = CGRect(
                    x: CGFloat(col) * cell + inset,
                    y: CGFloat(row) * cell + inset,
                    width: cell - inset * 2,
                    height: cell - inset * 2
                )
                let brightness = isStatic
                    ? (state == .idle || state == .ended ? 0.35 : 0.8)
                    : animatedBrightness(row: row, col: col, time: time)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: cell * 0.15),
                    with: .color(tint.opacity(brightness))
                )
            }
        }
    }

    private func animatedBrightness(row: Int, col: Int, time: TimeInterval) -> Double {
        switch state {
        case .executing:
            // Vague diagonale, 1,2 Hz.
            let phase = time * 2 * .pi * 1.2
            return 0.55 + 0.45 * sin(phase - Double(row + col) * 0.7)
        case .thinking:
            // Vague diagonale lente, amplitude réduite (0,5 Hz).
            let phase = time * 2 * .pi * 0.5
            return 0.70 + 0.20 * sin(phase - Double(row + col) * 0.7)
        case .waiting:
            // Rotation calme : un halo de lumière tourne autour du centre.
            let angle = time * 1.2
            let dx = Double(col) - 2, dy = Double(row) - 2
            guard dx != 0 || dy != 0 else { return 0.9 }
            let cellAngle = atan2(dy, dx)
            return 0.45 + 0.45 * max(0, cos(cellAngle - angle))
        case .idle, .ended:
            return 0.35
        }
    }

    /// Identicon 5×5 : 3 colonnes aléatoires (SplitMix64), symétrie verticale.
    static func pattern(seed: UInt64) -> [[Bool]] {
        var rng = SplitMix64(seed: seed)
        var grid = Array(repeating: Array(repeating: false, count: 5), count: 5)
        for row in 0..<5 {
            for col in 0..<3 {
                let on = rng.next() % 100 < 55
                grid[row][col] = on
                grid[row][4 - col] = on
            }
        }
        // Garantit au moins une cellule allumée (graine pathologique).
        if !grid.flatMap({ $0 }).contains(true) { grid[2][2] = true }
        return grid
    }
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
