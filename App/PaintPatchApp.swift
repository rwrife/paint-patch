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

    func select(_ candidate: Candidate, in room: Room) {
        save { _ = try $0.selectCandidate(candidate.id, in: room.id) }
    }

    func deselect(in room: Room) {
        save { _ = try $0.deselect(in: room.id) }
    }

    func logTouchUp(in room: Room, canLot: String, notes: String) {
        save { _ = try $0.logTouchUp(in: room.id, canLot: canLot, notes: notes) }
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
            VStack(spacing: 0) {
                Text("Paint Patch")
                    .font(.headline)
                    .accessibilityIdentifier("app.title")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                List {
                    Section("New room") {
                        TextField("Room name", text: $name)
                            .submitLabel(.done)
                            .accessibilityIdentifier("room.name")
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
            }
            .navigationTitle("Paint Patch")
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
                TextField("Sample label", text: $label)
                    .submitLabel(.done)
                    .accessibilityIdentifier("sample.label")
                TextField("Brand (optional)", text: $brand)
                    .submitLabel(.done)
                TextField("Can color code (optional)", text: $code)
                    .submitLabel(.done)
                    .accessibilityIdentifier("sample.code")
                TextField("Finish / sheen (optional)", text: $finish)
                    .submitLabel(.done)
                TextField("Patch location (optional)", text: $wall)
                    .submitLabel(.done)
                TextField("Can lot (optional)", text: $lot)
                    .submitLabel(.done)
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
            Section("Compare and record") {
                NavigationLink("Compare samples and log touch-ups") {
                    PaintWorkspaceLayout(notebook: notebook, room: room)
                }
                .accessibilityIdentifier("workspace.open")
            }
        }.navigationTitle(room.name)
    }
}

/// Single-screen iPhone composition seam. A future supported Duo SDK can move
/// gallery and controls to separate displays without changing record semantics.
struct PaintWorkspaceLayout: View {
    let notebook: Notebook
    let room: Room
    @State private var lot = ""
    @State private var notes = ""

    private var samples: [Candidate] {
        notebook.workspace.candidates.filter { $0.roomID == room.id }
    }

    private var selected: Candidate? {
        guard let id = notebook.workspace.selectedCandidateID(in: room.id) else { return nil }
        return samples.first { $0.id == id }
    }

    var body: some View {
        List {
            Section("Compare samples — photos and screens are not physical color measurements") {
                if samples.isEmpty {
                    Text("Add a sample to compare. No paint is selected.")
                }
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(samples) { candidate in
                            comparisonCard(candidate)
                                .frame(width: 240, alignment: .topLeading)
                                .padding()
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("workspace.gallery")
            }
            Section("Chosen paint and touch-up controls") {
                Text("Selected: \(selected?.label ?? "None")")
                    .font(.headline)
                    .accessibilityIdentifier("workspace.selected")
                if selected != nil {
                    Button("Clear selection") { notebook.deselect(in: room) }
                        .accessibilityIdentifier("workspace.clear")
                    TextField("Actual can lot (optional)", text: $lot)
                        .accessibilityIdentifier("workspace.lot")
                    TextField("Touch-up notes (optional)", text: $notes)
                    Button("Log applied touch-up") {
                        notebook.logTouchUp(in: room, canLot: lot, notes: notes)
                        if notebook.error == nil { lot = ""; notes = "" }
                    }
                    .accessibilityIdentifier("workspace.touchup")
                }
                Text("Choose explicitly. Unknown codes and finishes stay unknown. Check physical samples under real lighting before applying paint.")
                    .font(.caption)
            }
            Section("Selection history") {
                ForEach(notebook.workspace.selections.filter { $0.roomID == room.id }) { event in
                    let name = samples.first { $0.id == event.candidateID }?.label ?? "Cleared"
                    Text("\(name) · \(event.selectedAt.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            Section("Applied touch-ups") {
                ForEach(notebook.workspace.touchUps(in: room.id)) { event in
                    let name = samples.first { $0.id == event.candidateID }?.label ?? "Unknown"
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(name) · Lot: \(event.canLot ?? "Unknown")")
                        Text(event.appliedAt, format: .dateTime)
                        if let notes = event.notes { Text(notes) }
                    }
                }
            }
        }
        .navigationTitle("Compare · \(room.name)")
        .alert("Notebook error", isPresented: Binding(get: { notebook.error != nil },
                                                      set: { if !$0 { notebook.error = nil } })) {
            Button("OK") { notebook.error = nil }
        } message: { Text(notebook.error ?? "") }
    }

    private func comparisonCard(_ candidate: Candidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(candidate.label).font(.headline)
            Text("Brand: \(candidate.brand ?? "Unknown")")
            Text("Code: \(candidate.code ?? "Unknown")")
            Text("Finish: \(candidate.finish ?? "Unknown")")
            Text("Patch location: \(candidate.wallLocation ?? "Unknown")")
            Text("Can lot: \(candidate.canLot ?? "Unknown")")
            ForEach(notebook.workspace.observations.filter { $0.candidateID == candidate.id }) { observation in
                VStack(alignment: .leading, spacing: 4) {
                    Text(observation.observedAt, format: .dateTime)
                    Text("Lighting: \(observation.lighting ?? "Unknown")")
                    Text("Surface: \(observation.surface ?? "Unknown")")
                    if let notes = observation.notes { Text(notes) }
                    if let image = notebook.photo(observation.photoID) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .accessibilityLabel("User-selected patch photo; not a color measurement")
                    }
                }
            }
            let isSelected = selected?.id == candidate.id
            Text(isSelected ? "Selected" : "Not selected")
                .font(.subheadline.bold())
            Button(isSelected ? "Selected: \(candidate.label)" : "Choose \(candidate.label)") {
                notebook.select(candidate, in: room)
            }
            .accessibilityIdentifier("workspace.choose.\(candidate.label)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
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
                    .submitLabel(.done)
                    .accessibilityIdentifier("observation.lighting")
                TextField("Surface / patch location", text: $surface)
                    .submitLabel(.done)
                TextField("Notes (optional)", text: $notes)
                    .submitLabel(.done)
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
