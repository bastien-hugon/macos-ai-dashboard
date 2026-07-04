import SwiftUI

/// Forme du notch (05 · §3.1) : coins supérieurs concaves (la forme « s'accroche » au bord
/// de l'écran) et coins inférieurs convexes. Rayons fermés (6, 14), ouverts (19, 24).
/// Réécriture indépendante du concept popularisé par les apps notch open source (pas de code repris).
public struct NotchShape: InsettableShape {
    public var topCornerRadius: CGFloat
    public var bottomCornerRadius: CGFloat
    var insetAmount: CGFloat = 0

    public init(topCornerRadius: CGFloat, bottomCornerRadius: CGFloat) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    public func inset(by amount: CGFloat) -> NotchShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }

    public static let closed = NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
    public static let open = NotchShape(topCornerRadius: 19, bottomCornerRadius: 24)

    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    public func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let top = min(topCornerRadius, rect.height / 2, rect.width / 2)
        let bottom = min(bottomCornerRadius, rect.height / 2, rect.width / 2)
        var path = Path()
        // Bord supérieur gauche : courbe concave vers l'intérieur.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control: CGPoint(x: rect.minX + top, y: rect.minY)
        )
        // Flanc gauche.
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        // Coin inférieur gauche : convexe.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + top, y: rect.maxY)
        )
        // Bord inférieur.
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        // Coin inférieur droit.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - top, y: rect.maxY)
        )
        // Flanc droit.
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        // Bord supérieur droit : concave.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
