import AppKit
import SwiftUI
import Combine

/// Hosting view that accepts the first mouse click without requiring a prior activation click.
class IndicatorFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Shared behavior for the floating indicator panels (Notch, Overlay, Minimal).
///
/// Owns the panel configuration, Combine observation wiring, screen resolution,
/// and the default show/dismiss/refresh policy. Subclasses supply their sizing
/// and placement policy (`show`) and, where they genuinely diverge, override
/// `dismiss` / `refreshPlacementForActiveContextChange`.
class IndicatorPanelBase: NSPanel {
    let screenResolver: IndicatorScreenResolver
    let displayModeProvider: () -> NotchIndicatorDisplay
    private let windowLevel: NSWindow.Level
    private let indicatorStyle: IndicatorStyle
    var cancellables = Set<AnyCancellable>()
    var cachedScreen: NSScreen?

    init(
        screenResolver: IndicatorScreenResolver,
        displayModeProvider: @escaping () -> NotchIndicatorDisplay,
        indicatorStyle: IndicatorStyle,
        windowLevel: NSWindow.Level,
        contentRect: NSRect
    ) {
        self.screenResolver = screenResolver
        self.displayModeProvider = displayModeProvider
        self.windowLevel = windowLevel
        self.indicatorStyle = indicatorStyle
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        appearance = NSAppearance(named: .darkAqua)
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        FloatingPanelSpacePolicy.applyIndicatorPolicy(
            to: self,
            displayMode: displayModeProvider(),
            windowLevel: windowLevel
        )
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Observation

    func startObserving() {
        let vm = ServiceContainer.shared.dictationViewModel
        let recorder = ServiceContainer.shared.audioRecorderViewModel

        vm.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateVisibility(vm: vm, recorder: recorder)
            }
            .store(in: &cancellables)

        recorder.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateVisibility(vm: vm, recorder: recorder)
            }
            .store(in: &cancellables)

        vm.$notchIndicatorVisibility
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateVisibility(vm: vm, recorder: recorder)
            }
            .store(in: &cancellables)

        vm.$notchIndicatorDisplay
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.cachedScreen = nil
                self?.updateVisibility(vm: vm, recorder: recorder)
            }
            .store(in: &cancellables)

        observeStyleSpecificPublishers(vm: vm, recorder: recorder)

        vm.$actionFeedbackUndoTitle
            .receive(on: DispatchQueue.main)
            .sink { [weak self] undoTitle in
                self?.ignoresMouseEvents = undoTitle == nil
            }
            .store(in: &cancellables)
    }

    /// Hook for subclasses that observe additional publishers. Default: none.
    func observeStyleSpecificPublishers(vm: DictationViewModel, recorder: AudioRecorderViewModel) {}

    func updateVisibility(
        vm: DictationViewModel = ServiceContainer.shared.dictationViewModel,
        recorder: AudioRecorderViewModel = ServiceContainer.shared.audioRecorderViewModel
    ) {
        guard vm.indicatorStyle == indicatorStyle else {
            dismiss()
            return
        }

        let presentation = IndicatorPresentationState.resolve(
            dictationState: vm.state,
            recorderState: recorder.state
        )
        if IndicatorPresentationState.shouldShow(
            visibility: vm.notchIndicatorVisibility,
            presentation: presentation
        ) {
            show()
        } else {
            dismiss()
        }
    }

    // MARK: - Placement

    func resolveScreen() -> NSScreen {
        screenResolver.resolveScreen(for: displayModeProvider())
    }

    /// Orders the panel to the front using the shared indicator space policy.
    func orderIndicatorFront() {
        FloatingPanelSpacePolicy.orderIndicatorFront(
            self,
            displayMode: displayModeProvider(),
            windowLevel: windowLevel
        )
    }

    /// Subclasses size and place the panel here.
    func show() {}

    func refreshPlacementForActiveContextChange() {
        guard isVisible else { return }
        if displayModeProvider() == .activeScreen {
            cachedScreen = nil
        }
        show()
    }

    func dismiss() {
        cachedScreen = nil
        orderOut(nil)
    }
}

/// Shared base for the bottom/top floating indicator panels (Overlay, Minimal),
/// which differ only in their size and hosted SwiftUI view.
class FloatingIndicatorPanel: IndicatorPanelBase {
    private let panelWidth: CGFloat
    private let panelHeight: CGFloat

    init<RootView: View>(
        screenResolver: IndicatorScreenResolver,
        indicatorStyle: IndicatorStyle,
        panelWidth: CGFloat,
        panelHeight: CGFloat,
        rootView: RootView
    ) {
        self.panelWidth = panelWidth
        self.panelHeight = panelHeight
        super.init(
            screenResolver: screenResolver,
            displayModeProvider: { ServiceContainer.shared.dictationViewModel.notchIndicatorDisplay },
            indicatorStyle: indicatorStyle,
            windowLevel: FloatingPanelSpacePolicy.floatingIndicatorWindowLevel,
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        )

        let hostingView = IndicatorFirstMouseHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        contentView = hostingView
    }

    override func observeStyleSpecificPublishers(vm: DictationViewModel, recorder: AudioRecorderViewModel) {
        vm.$overlayPosition
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isVisible else { return }
                self.show()
            }
            .store(in: &cancellables)
    }

    override func show() {
        let screen: NSScreen
        if let cached = cachedScreen, isVisible {
            screen = cached
        } else {
            screen = resolveScreen()
            cachedScreen = screen
        }

        let overlayPosition = ServiceContainer.shared.dictationViewModel.overlayPosition
        let placement: IndicatorPlacement = overlayPosition == .top ? .notchStrip : .nonNotchArea
        if IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(on: screen, placement: placement) {
            suppressForForeignFullscreen()
            return
        }

        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - panelWidth / 2

        let y: CGFloat
        switch overlayPosition {
        case .bottom:
            y = screenFrame.origin.y + 20
        case .top:
            // Position below menu bar area, like a taskbar
            y = screenFrame.origin.y + screenFrame.height - panelHeight - 20
        }

        setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
        orderIndicatorFront()
    }

    private func suppressForForeignFullscreen() {
        cachedScreen = nil
        orderOut(nil)
    }
}
