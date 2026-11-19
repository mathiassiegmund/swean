import SwiftUI

enum LegalLinks {
    static let imprint = URL(string: "https://mathiassiegmund.de/impressum")!
}

struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Text("privacy.summary")
                    .font(.headline)
                    .padding(.vertical, 4)
            }
            Section("privacy.photos.title") {
                Text("privacy.photos.body")
            }
            Section("privacy.local.title") {
                Text("privacy.local.body")
            }
            Section("privacy.none.title") {
                Text("privacy.none.body")
            }
            Section("privacy.apple.title") {
                Text("privacy.apple.body")
            }
            Section("privacy.contact.title") {
                Text("privacy.contact.body")
                Link(destination: LegalLinks.imprint) {
                    Label("Legal Notice", systemImage: "info.circle")
                }
            }
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}
