import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers
import PaintPatchKit

struct NotebookExport: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

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
            error = nil
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

    /// Bytes only; nothing leaves the device unless the user saves the file via the system picker.
    func backupData() -> Data? {
        guard let repository else { error = "Notebook unavailable; nothing exported."; return nil }
        do {
            error = nil
            return try repository.makeBackup().encoded()
        } catch { self.error = "Backup failed: \(error.localizedDescription)"; return nil }
    }

    func csvData() -> Data? {
        do { return try workspace.inventoryCSV().data(using: .utf8) }
        catch { self.error = "Export failed: \(error.localizedDescription)"; return nil }
    }

    /// Preview already happened; restore stages photos then saves atomically with rollback.
    func restore(_ backup: BackupDocument) -> BackupPreview? {
        guard let repository else { error = "Notebook unavailable; nothing restored."; return nil }
        do {
            error = nil
            let preview = try repository.restore(backup)
            workspace = repository.workspace
            return preview
        } catch { self.error = "Restore failed: \(error.localizedDescription)"; return nil }
    }
}

struct BackupView: View {
    let notebook: Notebook
    @State private var backupDoc: NotebookExport?
    @State private var csvDoc: NotebookExport?
    @State private var pending: BackupDocument?
    @State private var preview: BackupPreview?
    @State private var restoring = false

    var body: some View {
        List {
            Section {
                Button("Prepare backup file") {
                    backupDoc = notebook.backupData().map { NotebookExport(data: $0) }
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("backup.prepare")
                Button("Prepare CSV inventory") {
                    csvDoc = notebook.csvData().map(NotebookExport.init(data:))
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("backup.csv")
            } header: {
                Text("Export — files are saved by you; Paint Patch never sends anything")
                    .foregroundStyle(.primary)
            }
            Section {
                Button("Choose backup file…") { chooseFile() }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("backup.import")
                if let preview {
                    counts(preview)
                    Button("Apply restore") { apply() }
                        .disabled(!preview.canApply)
                        .accessibilityIdentifier("backup.apply")
                    Button("Cancel") { self.preview = nil; pending = nil }
                } else {
                    Text("Nothing selected. Restore merges by record id; existing records win and duplicates are skipped.")
                        .font(.body)
                }
            } header: {
                Text("Restore — choose a backup file; nothing changes until you apply the preview")
                    .foregroundStyle(.primary)
            }
        }
        .navigationTitle("Backup & export")
        .fileExporter(isPresented: Binding(get: { backupDoc != nil }, set: { if !$0 { backupDoc = nil } }),
                      document: backupDoc ?? NotebookExport(data: Data()), contentType: .json,
                      defaultFilename: "paint-patch-backup") { _ in backupDoc = nil }
        .fileExporter(isPresented: Binding(get: { csvDoc != nil }, set: { if !$0 { csvDoc = nil } }),
                      document: csvDoc ?? NotebookExport(data: Data()), contentType: .commaSeparatedText,
                      defaultFilename: "paint-patch-inventory") { _ in csvDoc = nil }
        .fileImporter(isPresented: $restoring, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            ingest(result)
        }
        .alert("Notebook error", isPresented: Binding(get: { notebook.error != nil },
                                                      set: { if !$0 { notebook.error = nil } })) {
            Button("OK") { notebook.error = nil }
        } message: { Text(notebook.error ?? "") }
    }

    /// ponytail: system file pickers cannot be driven by XCUITest; this launch-argument fixture
    /// feeds the same decode/preview/apply path a picked file would. Real picker needs device QA.
    private func chooseFile() {
        guard ProcessInfo.processInfo.arguments.contains("-PPTestRestoreFixture") else { restoring = true; return }
        preview = nil
        pending = nil
        do {
            var fixture = PaintWorkspace()
            let room = try fixture.recordRoom("Restored Room")
            _ = try fixture.recordCandidate(roomID: room.id, label: "Restored can", brand: "", code: "",
                                            finish: "", wallLocation: "", canLot: "")
            let bytes = try BackupDocument.make(from: fixture) { _ in nil }.encoded()
            let document = try BackupDocument.decode(bytes)
            pending = document
            preview = document.preview(against: notebook.workspace)
        } catch { notebook.error = "Not a usable backup: \(error.localizedDescription)" }
    }

    private func counts(_ preview: BackupPreview) -> some View {
        Group {
            Text("Records to add: \(preview.newRecordCount)")
                .accessibilityIdentifier("backup.preview.new")
            Text("Rooms \(preview.rooms.new) new · \(preview.rooms.duplicate) duplicate")
            Text("Samples \(preview.candidates.new) new · \(preview.candidates.duplicate) duplicate")
            Text("Photos \(preview.photos.new) new · \(preview.photos.duplicate) duplicate")
            Text("Created \(preview.createdAt.formatted(date: .abbreviated, time: .shortened))")
            if !preview.canApply {
                Text("Restore conflict: existing records in this notebook conflict with incoming references.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("backup.preview.conflict")
            }
        }
    }

    private func ingest(_ result: Result<[URL], Error>) {
        preview = nil
        pending = nil
        switch result {
        case .failure(let error):
            notebook.error = "Could not read file: \(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            // Security-scoped, read into memory, then never touch the URL again.
            guard url.startAccessingSecurityScopedResource() else {
                notebook.error = "No permission to read that file."; return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url) else {
                notebook.error = "Could not read file."; return
            }
            do {
                let document = try BackupDocument.decode(data)
                pending = document
                preview = document.preview(against: notebook.workspace)
            } catch { notebook.error = "Not a usable backup: \(error.localizedDescription)" }
        }
    }

    private func apply() {
        guard let pending else { return }
        if notebook.restore(pending) != nil { self.pending = nil; preview = nil }
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
                        }
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("room.add")
                    }
                    Section("Rooms") {
                        ForEach(notebook.workspace.rooms) { room in
                            NavigationLink(room.name) { RoomView(notebook: notebook, room: room) }
                        }
                    }
                    Section {
                        NavigationLink("Backup, restore & export") {
                            BackupView(notebook: notebook)
                        }
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("app.backup")
                    } header: {
                        Text("Data & privacy").foregroundStyle(.primary)
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
    @State private var rename: String
    @State private var label = ""
    @State private var brand = ""
    @State private var code = ""
    @State private var finish = ""
    @State private var wall = ""
    @State private var lot = ""

    init(notebook: Notebook, room: Room) {
        self.notebook = notebook
        self.room = room
        _rename = State(initialValue: room.name)
    }

    private var currentName: String {
        notebook.workspace.rooms.first(where: { $0.id == room.id })?.name ?? room.name
    }

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
            Section("Rename room") {
                TextField("Room name", text: $rename)
                    .submitLabel(.done)
                    .accessibilityIdentifier("room.rename")
                Button("Save room name") {
                    notebook.save { try $0.renameRoom(room.id, to: rename) }
                }
                .accessibilityIdentifier("room.rename.save")
            }
        }
        .navigationTitle(currentName)
        .alert("Notebook error", isPresented: Binding(get: { notebook.error != nil },
                                                      set: { if !$0 { notebook.error = nil } })) {
            Button("OK") { notebook.error = nil }
        } message: { Text(notebook.error ?? "") }
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

struct SampleEditForm: View {
    let notebook: Notebook
    let candidate: Candidate
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var brand: String
    @State private var code: String
    @State private var finish: String
    @State private var wall: String
    @State private var lot: String

    init(notebook: Notebook, candidate: Candidate) {
        self.notebook = notebook
        self.candidate = candidate
        _label = State(initialValue: candidate.label)
        _brand = State(initialValue: candidate.brand ?? "")
        _code = State(initialValue: candidate.code ?? "")
        _finish = State(initialValue: candidate.finish ?? "")
        _wall = State(initialValue: candidate.wallLocation ?? "")
        _lot = State(initialValue: candidate.canLot ?? "")
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Edit sample — blank means unknown") {
                    TextField("Sample label", text: $label).submitLabel(.done)
                        .accessibilityIdentifier("edit.label")
                    TextField("Brand (optional)", text: $brand).submitLabel(.done)
                    TextField("Can color code (optional)", text: $code).submitLabel(.done)
                    TextField("Finish / sheen (optional)", text: $finish).submitLabel(.done)
                    TextField("Patch location (optional)", text: $wall).submitLabel(.done)
                    TextField("Can lot (optional)", text: $lot).submitLabel(.done)
                }
            }
            .navigationTitle("Edit \(candidate.label)")
            .safeAreaInset(edge: .bottom) {
                if let error = notebook.error {
                    Text(error).foregroundStyle(.red).padding()
                        .accessibilityIdentifier("sample.edit.error")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save changes") {
                        notebook.save {
                            try $0.reviseCandidate(candidate.id, label: label, brand: brand,
                                                   code: code, finish: finish,
                                                   wallLocation: wall, canLot: lot)
                        }
                        if notebook.error == nil { dismiss() }
                    }
                    .accessibilityIdentifier("sample.save")
                }
            }
        }
    }
}

struct SampleView: View {
    let notebook: Notebook
    let candidate: Candidate
    @State private var showingEdit = false
    @State private var lighting = ""
    @State private var surface = ""
    @State private var notes = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showCamera = false
    @State private var cameraJPEG: Data?

    private var currentCandidate: Candidate {
        notebook.workspace.candidates.first(where: { $0.id == candidate.id }) ?? candidate
    }

    /// Camera is requested only when the user taps; denial/absence keeps manual + picker paths.
    private func openCamera() {
        // ponytail: UI-test denial injection only; test real permission prompts on a device when available.
        if ProcessInfo.processInfo.arguments.contains("-PPTestCameraDenied") { denied(); return }
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
            Section("Sample facts — transcribed, not measured") {
                Text("Label: \(currentCandidate.label)")
                    .accessibilityIdentifier("sample.current.label")
                Text("Code: \(currentCandidate.code ?? "Unknown") · Finish: \(currentCandidate.finish ?? "Unknown")")
                    .font(.caption)
                    .accessibilityIdentifier("sample.current.facts")
                Button("Edit sample labels") { showingEdit = true }
                    .accessibilityIdentifier("sample.edit.open")
            }
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
        }
        .navigationTitle(currentCandidate.label)
        .sheet(isPresented: $showingEdit) {
            SampleEditForm(notebook: notebook, candidate: currentCandidate)
        }
        .alert("Notebook error", isPresented: Binding(get: { notebook.error != nil },
                                                      set: { if !$0 { notebook.error = nil } })) {
            Button("OK") { notebook.error = nil }
        } message: { Text(notebook.error ?? "") }
    }

    private func record() {
        notebook.save {
            _ = try $0.recordObservation(candidateID: candidate.id, lighting: lighting,
                                         surface: surface, notes: notes)
        }
        if notebook.error == nil { lighting = ""; surface = ""; notes = "" }
    }
}
