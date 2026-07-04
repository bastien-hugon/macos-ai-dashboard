import SwiftUI

/// Section injectée dans le panel par la composition root (05 · §3.1) :
/// NotchUI définit le conteneur, les titres et le scroll ; le contenu vient d'ailleurs
/// (règle « NotchUI ne dépend que de DashCore », 01 · §3.2).
@MainActor
public struct NotchSection: Identifiable {
    public let id: String
    public let title: String?
    /// Une section optionnelle vide est masquée entièrement (05 · REQ-NUI-36).
    public let isEmpty: Bool
    public let hidesWhenEmpty: Bool
    public let content: AnyView

    public init(
        id: String,
        title: String?,
        isEmpty: Bool = false,
        hidesWhenEmpty: Bool = false,
        @ViewBuilder content: () -> some View
    ) {
        self.id = id
        self.title = title
        self.isEmpty = isEmpty
        self.hidesWhenEmpty = hidesWhenEmpty
        self.content = AnyView(content())
    }
}
