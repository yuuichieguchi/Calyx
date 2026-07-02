// UnreadCountBadge.swift
// Calyx
//
// Shared unread-count badge used by AgentStatusView's row, and by
// SidebarContentView / TabBarContentView for a tab's unread
// notifications. A Capsule background (rather than a fixed-size Circle)
// grows to fit "99+" instead of squashing it into an ellipse sized for a
// single digit.

import SwiftUI

struct UnreadCountBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color.red)
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
            )
    }
}

#Preview {
    VStack(spacing: 8) {
        UnreadCountBadge(count: 1)
        UnreadCountBadge(count: 42)
        UnreadCountBadge(count: 150)
    }
    .padding()
}
