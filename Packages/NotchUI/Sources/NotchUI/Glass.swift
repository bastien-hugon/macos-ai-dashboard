import AppKit
import SwiftUI

/// Matériau de flou AppKit pour le fallback < macOS 26 (05 · REQ-NUI-45).
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

public extension View {
    /// Rendu « Liquid Glass » du panel (05 · REQ-NUI-40/45) :
    /// macOS 26 → `glassEffect` natif ; sinon `NSVisualEffectView` + voile noir.
    /// `opacity == 1.0` → noir opaque, matériau réellement absent de la hiérarchie.
    @ViewBuilder
    func agentGlass(in shape: some Shape, opacity: Double) -> some View {
        if opacity >= 1.0 {
            background(Color.black.clipShape(shape))
        } else if #available(macOS 26.0, *) {
            background {
                ZStack {
                    Color.clear.glassEffect(.regular, in: shape)
                    Color.black.opacity(opacity)
                }
                .clipShape(shape)
            }
        } else {
            background {
                ZStack {
                    VisualEffectView()
                    Color.black.opacity(opacity)
                }
                .clipShape(shape)
            }
        }
    }
}
