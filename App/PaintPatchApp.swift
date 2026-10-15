import SwiftUI
import AVFoundation
import PhotosUI
import PaintPatchKit

@main
struct PaintPatchApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

@MainActor @Observable
final class Notebook {
    private var repository: WorkspaceRepository?
    var workspace = PaintWorkspace()
    var error: String?

    init() {
        do {
            let arguments = ProcessInfo.processInfo.arguments
            var folder: URL
            if let index = arguments.firstIndex(of: "-PPTestContainerDirectory"),
               index + 1 < arguments.count {
                // UI-test isolation: fresh sandbox per run; never touches the user's notebook.
                folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            } else {
                folder = try FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask, appropriateFor: nil, create: true)
            }
            let store = try WorkspaceRepository(directory: folder)
            repository = store
            workspace = store.workspace
        } catch { self.error = "Could not open local notebook: \(error.localizedDescription)" }
    }

    func save(_ edit: (inout PaintWorkspace) throws -> Void) {
        guard let repository else { error = "Notebook unavailable; nothing saved."; return }
        do {
            try repository.change(edit)
            workspace = repository.workspace
        } catch { self.error = "Not saved: \(error.localizedDescription)" }
    }

    func attach(_ data: Data, candidateID: UUID, lighting: String, surface: String, notes: String) {
        guard let repository else { error = "Notebook unavailable; nothing saved."; return }
        do {
            let photo = try repository.addPhoto(data)
            do {
                try repository.change {
                    try $0.recordObservation(candidateID: candidateID, lighting: lighting,
                                             surface: surface, notes: notes, photoID: photo.id)
                }
            } catch {
                try? repository.change { $0.removePhoto(id: photo.id) }
                try? FileManager.default.removeItem(at: repository.photoURL(photo))
                throw error
            }
            workspace = repository.workspace
        } catch { self.error = "Photo not saved: \(error.localizedDescription)" }
    }

    func photo(_ id: UUID?) -> UIImage? {
        guard let id, let repository,
              let ref = workspace.photos.first(where: { $0.id == id }),
              let data = try? Data(contentsOf: repository.photoURL(ref)) else { return nil }
        return UIImage(data: data)
    }
}

struct CameraCapture: UIViewControllerRepresentable {
    @Binding var jpeg: Data?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image"]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCapture
        init(_ parent: CameraCapture) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let jpeg = image.jpegData(compressionQuality: 0.85) {
                parent.jpeg = jpeg
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true) }
    }
}

struct ContentView: View {
    @State private var notebook = Notebook()
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                Section("New room") {
                    TextField("Room name", text: $name).accessibilityIdentifier("room.name")
                    Button("Add room") {
                        notebook.save { _ = try $0.recordRoom(name) }
                        if notebook.error == nil { name = "" }
                    }.accessibilityIdentifier("room.add")
                }
                Section("Rooms") {
                    ForEach(notebook.workspace.rooms) { room in
                        NavigationLink(room.name) { RoomView(notebook: notebook, room: room) }
                    }
                }
            }
            .navigationTitle("Paint Patch")
            .toolbar { ToolbarItem(placement: .principal) {
                Text("Paint Patch").accessibilityIdentifier("app.title")
            } }
            .alert("Notebook error", isPresented: Binding(get: { notebook.error != nil },
                                                          set: { if !$0 { notebook.error = nil } })) {
                Button("OK") { notebook.error = nil }
            } message: { Text(notebook.error ?? "") }
        }
    }
}

struct RoomView: View {
    let notebook: Notebook
    let room: Room
    @State private var label = ""
    @State private var brand = ""
    @State private var code = ""
    @State private var finish = ""
    @State private var wall = ""
    @State private var lot = ""

    var body: some View {
        List {
            Section("New sample — transcribe can label; blank means unknown") {
                TextField("Sample label", text: $label).accessibilityIdentifier("sample.label")
                TextField("Brand (optional)", text: $brand)
                TextField("Can color code (optional)", text: $code).accessibilityIdentifier("sample.code")
                TextField("Finish / sheen (optional)", text: $finish)
                TextField("Patch location (optional)", text: $wall)
                TextField("Can lot (optional)", text: $lot)
                Button("Add sample") {
                    notebook.save {
                        _ = try $0.recordCandidate(roomID: room.id, label: label, brand: brand,
                                                   code: code, finish: finish, wallLocation: wall,
                                                   canLot: lot)
                    }
                    if notebook.error == nil { label = ""; brand = ""; code = ""; finish = ""; wall = ""; lot = "" }
                }.accessibilityIdentifier("sample.add")
            }
            Section("Samples — photos are not color measurements") {
                ForEach(notebook.workspace.candidates.filter { $0.roomID == room.id }) { candidate in
                    NavigationLink {
                        SampleView(notebook: notebook, candidate: candidate)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(candidate.label)
                            Text("Code: \(candidate.code ?? "Unknown") · Finish: \(candidate.finish ?? "Unknown")")
                                .font(.caption)
                        }
                    }
                }
            }
        }.navigationTitle(room.name)
    }
}

struct SampleView: View {
    let notebook: Notebook
    let candidate: Candidate
    @State private var lighting = ""
    @State private var surface = ""
    @State private var notes = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showCamera = false
    @State private var cameraJPEG: Data?

    /// Camera is requested only when the user taps; denial/absence keeps manual + picker paths.
    private func openCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            notebook.error = "No camera available. Save notes or choose a photo instead."
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: showCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted { showCamera = true } else { denied() }
                }
            }
        default: denied()
        }
    }

    private func denied() {
        notebook.error = "Camera access is off. Enable it in Settings, or save notes / choose a photo instead."
    }

    var body: some View {
        List {
            Section("Record patch — lighting is your description, not a color match") {
                TextField("Lighting (e.g. morning daylight)", text: $lighting)
                    .accessibilityIdentifier("observation.lighting")
                TextField("Surface / patch location", text: $surface)
                TextField("Notes (optional)", text: $notes)
                Button("Save observation without photo") { record() }
                    .accessibilityIdentifier("observation.save")
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("Choose photo and save observation", systemImage: "photo")
                }
                .accessibilityIdentifier("observation.photo")
                Button { openCamera() } label: {
                    Label("Take photo and save observation", systemImage: "camera")
                }.accessibilityIdentifier("observation.camera")
                .fullScreenCover(isPresented: $showCamera) {
                    CameraCapture(jpeg: $cameraJPEG).ignoresSafeArea()
                }
                .onChange(of: cameraJPEG) { _, data in
                    guard let data else { return }
                    notebook.attach(data, candidateID: candidate.id, lighting: lighting,
                                    surface: surface, notes: notes)
                    cameraJPEG = nil
                }
                .onChange(of: selectedPhoto) { _, item in
                    guard let item else { return }
                    Task {
                        do {
                            guard let data = try await item.loadTransferable(type: Data.self),
                                  let image = UIImage(data: data),
                                  let jpeg = image.jpegData(compressionQuality: 0.85) else {
                                notebook.error = "Photo unavailable. Save notes without a photo."
                                return
                            }
                            notebook.attach(jpeg, candidateID: candidate.id, lighting: lighting,
                                            surface: surface, notes: notes)
                        } catch { notebook.error = "Photo unavailable. Save notes without a photo." }
                        selectedPhoto = nil
                    }
                }
                Text("Photo access uses system picker only. No broad library permission needed.")
                    .font(.caption)
            }
            Section("Observations") {
                ForEach(notebook.workspace.observations.filter { $0.candidateID == candidate.id }) { observation in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(observation.observedAt, format: .dateTime)
                        Text("Lighting: \(observation.lighting ?? "Unknown")")
                        Text("Surface: \(observation.surface ?? "Unknown")")
                        if let notes = observation.notes { Text(notes) }
                        if let photo = notebook.photo(observation.photoID) {
                            Image(uiImage: photo).resizable().scaledToFit()
                                .accessibilityLabel("User-selected patch photo; not a color measurement")
                        }
                    }
                }
            }
        }.navigationTitle(candidate.label)
    }

    private func record() {
        notebook.save {
            _ = try $0.recordObservation(candidateID: candidate.id, lighting: lighting,
                                         surface: surface, notes: notes)
        }
        if notebook.error == nil { lighting = ""; surface = ""; notes = "" }
    }
}
