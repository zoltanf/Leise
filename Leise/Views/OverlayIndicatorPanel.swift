import AppKit
import SwiftUI

/// Floating panel for the Overlay Indicator mode.
class OverlayIndicatorPanel: FloatingIndicatorPanel {
    init(screenResolver: IndicatorScreenResolver) {
        super.init(
            screenResolver: screenResolver,
            indicatorStyle: .overlay,
            panelWidth: 500,
            panelHeight: 300,
            rootView: OverlayIndicatorView()
        )
    }
}
