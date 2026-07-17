import AppKit
import SwiftUI

/// Floating panel for the compact minimal indicator mode.
class MinimalIndicatorPanel: FloatingIndicatorPanel {
    init(screenResolver: IndicatorScreenResolver) {
        super.init(
            screenResolver: screenResolver,
            indicatorStyle: .minimal,
            panelWidth: 420,
            panelHeight: 160,
            rootView: MinimalIndicatorView()
        )
    }
}
