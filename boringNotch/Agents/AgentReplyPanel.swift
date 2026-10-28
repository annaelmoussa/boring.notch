//
//  AgentReplyPanel.swift
//  boringNotch
//

import AppKit
import SwiftUI

/// A small floating field, under the notch, that types a reply into an agent's terminal.
/// The notch window never takes keyboard focus, so typing happens in this panel instead,
/// which accepts keys without activating the app.
final class AgentReplyPanel: NSPanel {
    private static var current: AgentReplyPanel?

    /// Shows the field under the notch of the screen the pointer is on.
    static func show(for session: AgentSession) {
        current?.close()
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main else { return }

        let size = NSSize(width: 460, height: 52)
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - screen.safeAreaInsets.top - size.height - 12)
        let panel = AgentReplyPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = NSHostingView(rootView: ReplyField(session: session) { [weak panel] in panel?.close() })
        panel.makeKeyAndOrderFront(nil)
        current = panel
    }

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        level = .mainMenu + 4
        isFloatingPanel = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }

    /// Clicking elsewhere dismisses the field.
    override func resignKey() {
        super.resignKey()
        close()
    }

    override func close() {
        super.close()
        if Self.current === self { Self.current = nil }
    }
}

private struct ReplyField: View {
    let session: AgentSession
    let dismiss: () -> Void

    @State private var text = ""
    @State private var failed = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .foregroundStyle(.secondary)
            TextField("Reply to \(AgentsManager.shared.displayName(of: session.agent))…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isFocused)
                .onSubmit(send)
            if failed {
                Text("Could not reach the terminal")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .onAppear { isFocused = true }
        .onExitCommand(perform: dismiss)
    }

    private func send() {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return dismiss() }
        Task {
            if await AgentsManager.shared.reply(to: session, text: reply) {
                dismiss()
            } else {
                failed = true
            }
        }
    }
}
