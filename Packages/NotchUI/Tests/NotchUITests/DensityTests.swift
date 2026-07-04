import DashCore
import Testing
@testable import NotchUI

@Suite("DensityMetrics (05 · REQ-NUI-37)")
struct DensityMetricsTests {
    @Test("les trois densités produisent des hauteurs de rangée distinctes et croissantes")
    func distinctRowHeights() {
        let compact = DensityMetrics.metrics(for: .compact, titleWeight: .semibold)
        let regular = DensityMetrics.metrics(for: .regular, titleWeight: .semibold)
        let colossal = DensityMetrics.metrics(for: .colossal, titleWeight: .semibold)
        #expect(compact.rowHeight < regular.rowHeight)
        #expect(regular.rowHeight < colossal.rowHeight)
        #expect(compact.avatarSide < colossal.avatarSide)
    }

    @Test("les couleurs d'état sont distinctes")
    func stateTints() {
        #expect(SessionState.executing.tint != SessionState.waiting.tint)
        #expect(SessionState.waiting.tint != SessionState.idle.tint)
    }
}
