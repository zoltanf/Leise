import AppKit
import SwiftUI
import Combine

/// Observable notch geometry passed from the panel to the SwiftUI view.
@MainActor
final class NotchGeometry: ObservableObject {
    @Published var notchWidth: CGFloat = 185
    @Published var notchHeight: CGFloat = NotchIndicatorLayout.notchedClosedHeight
    @Published var hasNotch: Bool = false
    @Published var isPresented: Bool = false

    func update(for screen: NSScreen) {
        hasNotch = screen.safeAreaInsets.top > 0
        if hasNotch,
           let left = screen.auxiliaryTopLeftArea?.width,
           let right = screen.auxiliaryTopRightArea?.width {
            notchWidth = screen.frame.width - left - right + 4
        } else {
            notchWidth = 0
        }
        notchHeight = NotchIndicatorLayout.closedHeight(
            hasNotch: hasNotch,
            safeAreaTopInset: screen.safeAreaInsets.top
        )
    }
}

/// Panel that visually extends the MacBook notch, centered over the hardware notch.
/// Only shown on displays with a hardware notch - hidden on non-notch displays regardless of settings.
class NotchIndicatorPanel: IndicatorPanelBase {
    /// Large enough to accommodate the expanded (open) state. SwiftUI clips the visible area.
    private static let panelWidth: CGFloat = 500
    private static let panelHeight: CGFloat = 500
    private static let presentationAnimationDuration: Duration = .milliseconds(220)

    private let notchGeometry = NotchGeometry()
    private var showTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    convenience init(screenResolver: IndicatorScreenResolver) {
        self.init(
            screenResolver: screenResolver,
            displayModeProvider: { ServiceContainer.shared.dictationViewModel.notchIndicatorDisplay },
            content: { NotchIndicatorView(geometry: $0) }
        )
    }

    init<Content: View>(
        screenResolver: IndicatorScreenResolver,
        displayModeProvider: @escaping () -> NotchIndicatorDisplay,
        @ViewBuilder content: (NotchGeometry) -> Content
    ) {
        super.init(
            screenResolver: screenResolver,
            displayModeProvider: displayModeProvider,
            indicatorStyle: .notch,
            windowLevel: FloatingPanelSpacePolicy.notchIndicatorWindowLevel,
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)
        )

        let hostingView = IndicatorFirstMouseHostingView(rootView: content(notchGeometry))
        hostingView.sizingOptions = []
        contentView = hostingView
    }

    // MARK: - Notch geometry

    override func show() {
        showTask?.cancel()
        dismissTask?.cancel()

        let wasVisible = isVisible
        placePanel()

        guard !wasVisible else {
            if !notchGeometry.isPresented {
                withAnimation(.easeOut(duration: 0.22)) {
                    notchGeometry.isPresented = true
                }
            }
            return
        }

        notchGeometry.isPresented = false
        showTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                self.notchGeometry.isPresented = true
            }
            self.showTask = nil
        }
    }

    private func placePanel() {
        let screen: NSScreen
        if let cached = cachedScreen, isVisible {
            screen = cached
        } else {
            screen = resolveScreen()
            cachedScreen = screen
        }

        notchGeometry.update(for: screen)

        let screenFrame = screen.frame
        let x = screenFrame.midX - Self.panelWidth / 2
        let y = screenFrame.origin.y + screenFrame.height - Self.panelHeight

        setFrame(NSRect(x: x, y: y, width: Self.panelWidth, height: Self.panelHeight), display: true)
        orderIndicatorFront()
    }

    override func refreshPlacementForActiveContextChange() {
        guard isVisible, notchGeometry.isPresented else { return }
        if displayModeProvider() == .activeScreen {
            cachedScreen = nil
        }
        placePanel()
    }

    override func dismiss() {
        cachedScreen = nil
        showTask?.cancel()
        showTask = nil
        dismissTask?.cancel()

        guard isVisible else {
            notchGeometry.isPresented = false
            orderOut(nil)
            return
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            notchGeometry.isPresented = false
        }

        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.presentationAnimationDuration)
            guard !Task.isCancelled else { return }
            guard let self, !self.notchGeometry.isPresented else { return }
            self.orderOut(nil)
            self.dismissTask = nil
        }
    }
}
