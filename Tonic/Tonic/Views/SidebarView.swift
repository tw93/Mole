//
//  SidebarView.swift
//  Tonic
//
//  Sidebar navigation component
//

import SwiftUI

struct SidebarView: View {
    @Binding var selectedDestination: NavigationDestination
    @State private var isProUser: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // App header
            HStack {
                Image(systemName: "drop.circle.fill")
                    .font(.title2)
                    .foregroundColor(TonicColors.accent)

                Text("Tonic")
                    .font(.headline)
                    .fontWeight(.semibold)

                Spacer()

                if isProUser {
                    Image(systemName: "crown.fill")
                        .font(.caption)
                        .foregroundColor(TonicColors.pro)
                }
            }
            .padding()

            Divider()

            // Navigation list
            List(selection: $selectedDestination) {
                ForEach(NavigationDestination.allCases, id: \.self) { destination in
                    Label(destination.rawValue, systemImage: destination.systemImage)
                        .tag(destination)
                }
            }
            .listStyle(.sidebar)
        }
    }
}

#Preview {
    SidebarView(selectedDestination: .constant(.dashboard))
}
