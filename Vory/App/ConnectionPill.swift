import SwiftUI
import VoryCore

/// Small glass status pill used in navigation bars.
struct ConnectionPill: View {
    var state: SocketState
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(state.label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .accessibilityLabel("Connection: \(state.label)")
    }
    private var color: Color {
        switch state {
        case .open: return .green
        case .connecting, .reconnecting: return .orange
        case .authRejected, .failed: return .red
        case .idle: return .gray
        }
    }
}
