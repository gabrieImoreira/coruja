import Foundation

/// Recording state shared with the notes window's control bar, so it stays
/// in sync no matter which surface (menu bar, Dock, hotkey, meeting prompt)
/// started or stopped the recording.
@MainActor
final class RecordingStatus: ObservableObject {
    @Published var isRecording = false
    @Published var elapsed: String?
}
