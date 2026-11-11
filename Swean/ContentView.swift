import SwiftUI
import Photos

struct ContentView: View {
    @Environment(PhotoLibrary.self) private var library

    var body: some View {
        switch library.status {
        case .authorized, .limited:
            HomeView()
        case .notDetermined:
            WelcomeView()
        default:
            DeniedView()
        }
    }
}

private struct WelcomeView: View {
    @Environment(PhotoLibrary.self) private var library

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
            Text(verbatim: "Swean")
                .font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 14) {
                FeatureRow(icon: "arrow.up", color: .red, text: "Swipe up: move to trash")
                FeatureRow(icon: "arrow.left", color: .green, text: "Swipe left: keep")
                FeatureRow(icon: "arrow.right", color: .blue, text: "Swipe right: go back")
                FeatureRow(icon: "rectangle.stack.badge.plus", color: .accentColor, text: "Tap an album: file the photo")
            }
            .padding(.horizontal, 32)
            Spacer()
            Button {
                Task { await library.requestAccess() }
            } label: {
                Text("Allow Access to Photos")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            Text("Your photos never leave your iPhone.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom)
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let color: Color
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(color, in: RoundedRectangle(cornerRadius: 10))
            Text(text)
        }
    }
}

private struct DeniedView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Access to Photos", systemImage: "photo.badge.exclamationmark")
        } description: {
            Text("Allow Swean to access all photos in Settings.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
