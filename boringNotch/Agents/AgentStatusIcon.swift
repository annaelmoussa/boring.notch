//
//  AgentStatusIcon.swift
//  boringNotch
//

import AppKit
import SwiftUI

/// One family of round status marks: a spinning arc while working, solid badges when the agent
/// needs the user or is done, and a plain ring when idle.
struct AgentStatusIcon: View {
    let status: AgentStatus
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            switch status {
            case .working:
                Spinner(color: NSColor(status.color), lineWidth: max(1.5, size * 0.13))
            case .needsInput:
                badge(symbol: "exclamationmark")
            case .done:
                badge(symbol: "checkmark")
            case .idle:
                Circle()
                    .strokeBorder(status.color.opacity(0.7), lineWidth: max(1.5, size * 0.12))
                    .padding(size * 0.08)
            }
        }
        .frame(width: size, height: size)
    }

    private func badge(symbol: String) -> some View {
        Circle()
            .fill(status.color)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .heavy))
                    .foregroundStyle(.black.opacity(0.85))
            }
    }
}

/// An arc turning over a faint track. The rotation is a Core Animation animation, run by the
/// render server rather than by the app, so it costs the app nothing while it spins.
private struct Spinner: NSViewRepresentable {
    let color: NSColor
    let lineWidth: CGFloat

    func makeNSView(context: Context) -> SpinnerView {
        SpinnerView()
    }

    func updateNSView(_ view: SpinnerView, context: Context) {
        view.configure(color: color, lineWidth: lineWidth)
    }

    final class SpinnerView: NSView {
        private let track = CAShapeLayer()
        private let arc = CAShapeLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for shape in [track, arc] {
                shape.fillColor = nil
                shape.lineCap = .round
                layer?.addSublayer(shape)
            }
            arc.strokeEnd = 0.3
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(color: NSColor, lineWidth: CGFloat) {
            track.strokeColor = color.withAlphaComponent(0.25).cgColor
            arc.strokeColor = color.cgColor
            track.lineWidth = lineWidth
            arc.lineWidth = lineWidth
            needsLayout = true
        }

        override func layout() {
            super.layout()
            let inset = track.lineWidth / 2
            let path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
            for shape in [track, arc] {
                shape.frame = bounds
                shape.path = path
            }
        }

        // The animation only exists while the view is on screen.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            arc.removeAllAnimations()
            guard window != nil else { return }
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = 0
            rotation.toValue = -2 * Double.pi
            rotation.duration = 1
            rotation.repeatCount = .infinity
            // A small spinner looks just as smooth at 30 fps, at half the compositing work.
            rotation.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            arc.add(rotation, forKey: "spin")
        }
    }
}
