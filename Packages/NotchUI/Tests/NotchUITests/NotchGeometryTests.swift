import CoreGraphics
import Testing
@testable import NotchUI

@Suite("NotchGeometry (05 · REQ-NUI-12/13)")
struct NotchGeometryTests {
    @Test("écran notché : pill de repos = largeur notch + débord de 4 pt")
    func physicalNotch() {
        // Calibré sur le MacBook réel : notch 220×38, barre de menus 39.
        let geo = NotchGeometry(screenUUID: "u", hasPhysicalNotch: true,
                                notchSize: CGSize(width: 220, height: 38), menuBarHeight: 39)
        #expect(geo.pillRestSize.width == 224) // 220 + 4 (anti-crénelage)
        #expect(geo.pillRestSize.height == 38)
    }

    @Test("écran externe sans notch : fausse encoche 190 × hauteur barre de menus")
    func externalFakeNotch() {
        let geo = NotchGeometry(screenUUID: "u", hasPhysicalNotch: false,
                                notchSize: .zero, menuBarHeight: 24)
        #expect(geo.pillRestSize.width == NotchGeometry.externalPillWidth) // 190
        #expect(geo.pillRestSize.height == 24)
    }

    @Test("écran externe barre masquée : plancher de hauteur à 24 pt")
    func externalHiddenMenuBar() {
        let geo = NotchGeometry(screenUUID: "u", hasPhysicalNotch: false,
                                notchSize: .zero, menuBarHeight: 0)
        #expect(geo.pillRestSize.height == 24) // plancher
    }

    @Test("largeur des ailes selon le mode")
    func wingWidths() {
        let geo = NotchGeometry(screenUUID: "u", hasPhysicalNotch: true,
                                notchSize: CGSize(width: 200, height: 38), menuBarHeight: 39)
        #expect(geo.wingWidth(mode: .wide) < geo.wingWidth(mode: .ultraWide))
    }
}
