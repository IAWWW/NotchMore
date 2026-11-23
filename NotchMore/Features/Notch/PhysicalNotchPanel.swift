import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class PhysicalNotchPanel {
    let window: NSPanel

    private let presentation = Presentation()
    private let screen: NSScreen
    private var displayLink: CADisplayLink?
    private static let duration = 0.32

    @MainActor
    private final class Presentation: NSObject, ObservableObject {
        @Published var expanded = false
        @Published private(set) var progress: CGFloat = 0

        private var startTime: CFTimeInterval = 0
        private var startProgress: CGFloat = 0

        func begin(expanding: Bool) {
            startProgress = progress
            startTime = CACurrentMediaTime()
            expanded = expanding
        }

        func finish() {
            progress = expanded ? 1 : 0
        }

        @objc func advance(_ link: CADisplayLink) {
            let fraction = max(0, (link.targetTimestamp - startTime) / PhysicalNotchPanel.duration)
            guard fraction < 1 else {
                finish()
                link.invalidate()
                return
            }

            let t = CGFloat(fraction)
            let eased = t * t * (3 - 2 * t)
            let target: CGFloat = expanded ? 1 : 0
            progress = startProgress + (target - startProgress) * eased
        }
    }

    static func cutout(on screen: NSScreen) -> NSRect? {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
              right.minX > left.maxX, screen.safeAreaInsets.top > 0
        else { return nil }

        return NSRect(
            x: left.maxX,
            y: screen.frame.maxY - screen.safeAreaInsets.top,
            width: right.minX - left.maxX,
            height: screen.safeAreaInsets.top
        )
    }

    init(
        screen: NSScreen, cutout: NSRect, content: CombinedNotchView,
        onHoverChange: @escaping () -> Void = {}
    ) {
        self.screen = screen
        let size = NSSize(
            width: screen.frame.width / 2 + NotchLayout.expandedSafeAreaInset * 2,
            height: screen.frame.height / 2
        )
        let frame = NSRect(
            x: cutout.midX - size.width / 2, y: cutout.maxY - size.height,
            width: size.width, height: size.height
        )
        window = KeyPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.animationBehavior = .none
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.contentView = NSHostingView(rootView: PanelContent(
            presentation: presentation, cutoutSize: cutout.size, content: content,
            onHoverChange: onHoverChange
        ))
        window.setFrame(frame, display: false)
    }

    func expand() {
        if !window.isVisible {
            window.contentView?.layoutSubtreeIfNeeded()
            window.orderFrontRegardless()
        }
        animate(expanding: true)
    }

    func hide() async {
        animate(expanding: false)
        do {
            try await Task.sleep(for: .seconds(Self.duration))
        } catch {
            return
        }
        displayLink?.invalidate()
        displayLink = nil
        presentation.finish()
        window.orderOut(nil)
    }

    private func animate(expanding: Bool) {
        displayLink?.invalidate()
        presentation.begin(expanding: expanding)

        let link = screen.displayLink(target: presentation, selector: #selector(Presentation.advance(_:)))
        let maximum = Float(screen.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: min(60, maximum), maximum: maximum, preferred: maximum
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private struct PanelContent: View {
        @ObservedObject var presentation: Presentation
        let cutoutSize: CGSize
        let content: CombinedNotchView
        let onHoverChange: () -> Void

        var body: some View {
            content
                .fixedSize()
                .padding(.top, cutoutSize.height)
                .padding(.bottom, NotchLayout.expandedSafeAreaInset)
                .padding(.horizontal, NotchLayout.expandedSafeAreaInset * 2)
                .modifier(PhysicalNotchTransition(
                    progress: presentation.progress,
                    cutoutSize: cutoutSize
                ))
                .onHover { _ in onHoverChange() }
                .allowsHitTesting(presentation.expanded)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
        }
    }
}

private struct PhysicalNotchTransition: ViewModifier {
    let progress: CGFloat
    let cutoutSize: CGSize

    func body(content: Content) -> some View {
        content
            .opacity(min(1, progress / 0.2))
            .background(.black)
            .mask {
                PhysicalNotchShape(progress: progress, cutoutSize: cutoutSize)
            }
            .opacity(min(1, progress / 0.08))
    }
}

struct PhysicalNotchShape: Shape {
    let progress: CGFloat
    let cutoutSize: CGSize

    func path(in rect: CGRect) -> Path {
        let p = min(1, max(0, progress))
        // The center leads the sides on opening and trails them on closing.
        let stretch = p * (1 - p)
        let widthProgress = p - 0.48 * stretch
        let heightProgress = p + 0.72 * stretch
        let width = cutoutSize.width + (max(rect.width, cutoutSize.width) - cutoutSize.width) * widthProgress
        let height = cutoutSize.height + (max(rect.height, cutoutSize.height) - cutoutSize.height) * heightProgress

        let wave = 4 * stretch
        let top = rect.minY
        let bottom = top + height
        let edgeBottom = bottom - min(22, height * 0.13) * wave
        let left = rect.midX - width / 2
        let right = rect.midX + width / 2
        let shoulder = 15 * p + 4 * wave
        let neck = shoulder + min(16, width * 0.05) * wave
        let corner = max(0, min(edgeBottom - top - shoulder, width / 2 - neck, 8 + 12 * p))

        let shoulderY = top + shoulder
        let wallBottom = edgeBottom - corner
        let wallCurve = (wallBottom - shoulderY) / 3
        let leftEdge = left + shoulder + corner
        let rightEdge = right - shoulder - corner
        let baseCurve = (rect.midX - leftEdge) / 2

        var path = Path()
        path.move(to: CGPoint(x: left, y: top))
        path.addQuadCurve(
            to: CGPoint(x: left + neck, y: shoulderY),
            control: CGPoint(x: left + neck, y: top)
        )
        path.addCurve(
            to: CGPoint(x: left + shoulder, y: wallBottom),
            control1: CGPoint(x: left + neck, y: shoulderY + wallCurve),
            control2: CGPoint(x: left + shoulder, y: wallBottom - wallCurve)
        )
        path.addQuadCurve(
            to: CGPoint(x: leftEdge, y: edgeBottom),
            control: CGPoint(x: left + shoulder, y: edgeBottom)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: bottom),
            control1: CGPoint(x: leftEdge + baseCurve, y: edgeBottom),
            control2: CGPoint(x: rect.midX - baseCurve, y: bottom)
        )
        path.addCurve(
            to: CGPoint(x: rightEdge, y: edgeBottom),
            control1: CGPoint(x: rect.midX + baseCurve, y: bottom),
            control2: CGPoint(x: rightEdge - baseCurve, y: edgeBottom)
        )
        path.addQuadCurve(
            to: CGPoint(x: right - shoulder, y: wallBottom),
            control: CGPoint(x: right - shoulder, y: edgeBottom)
        )
        path.addCurve(
            to: CGPoint(x: right - neck, y: shoulderY),
            control1: CGPoint(x: right - shoulder, y: wallBottom - wallCurve),
            control2: CGPoint(x: right - neck, y: shoulderY + wallCurve)
        )
        path.addQuadCurve(
            to: CGPoint(x: right, y: top),
            control: CGPoint(x: right - neck, y: top)
        )
        path.closeSubpath()
        return path
    }
}
