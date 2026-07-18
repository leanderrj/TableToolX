import SwiftUI

struct AnyLabelStyle: LabelStyle {
    private let makeBody: (Configuration) -> AnyView

    init<S: LabelStyle>(_ style: S) {
        makeBody = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { makeBody(configuration) }

    static let iconOnly = AnyLabelStyle(IconOnlyLabelStyle())
    static let titleAndIcon = AnyLabelStyle(TitleAndIconLabelStyle())
}
