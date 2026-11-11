import PhotosUI
import SwiftUI
import UIKit

/// One photo of a meal and its analysis. A meal can consist of several photos (main dish, side,
/// dessert); their estimates add up to one entry.
struct MealPhotoPart: Identifiable {
    enum Status {
        case analyzing
        case done(MealPhotoAnalysis)
        case failed(String)
    }

    let id = UUID()
    let image: UIImage
    var status: Status

    var analysis: MealPhotoAnalysis? {
        if case let .done(analysis) = status { return analysis }
        return nil
    }

    var isAnalyzing: Bool {
        if case .analyzing = status { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }
}

/// Camera capture via UIKit (SwiftUI has no camera view).
struct CameraImagePicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: UIImagePickerController, context _: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraImagePicker
        init(_ parent: CameraImagePicker) { self.parent = parent }

        func imagePickerController(
            _: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// Shows the analysis of one or more photos of a meal and lets the user take over the sum into the
/// treatment fields.
struct MealPhotoAnalysisSheet: View {
    let parts: [MealPhotoPart]
    let combined: MealPhotoAnalysis?
    /// Fat and protein can only be entered when the FPU conversion is enabled.
    let fatProteinEnabled: Bool
    let onApply: (MealPhotoAnalysis) -> Void
    let onRetry: (UUID) -> Void
    let onRemove: (UUID) -> Void
    let onAddImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Upper limit of photos per meal, also per selection in the library.
    static let maxPhotos = 6

    @State private var showSourceDialog = false
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var capturedImage: UIImage?
    @State private var libraryItems: [PhotosPickerItem] = []

    private var isAnalyzing: Bool { parts.contains(where: \.isAnalyzing) }

    private var gramsFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }

    private var fpuFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter
    }

    private func grams(_ value: Decimal) -> String {
        (gramsFormatter.string(from: value as NSNumber) ?? "0") + " g"
    }

    var body: some View {
        NavigationStack {
            List {
                photoSection

                if let combined {
                    resultSections(combined)
                } else if isAnalyzing {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Analyzing meal…")
                        }
                    }
                }
            }
            .navigationTitle("Meal Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .confirmationDialog(
                String(localized: "Add Another Photo"),
                isPresented: $showSourceDialog,
                titleVisibility: .visible
            ) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button(String(localized: "Take Photo")) { showCamera = true }
                }
                Button(String(localized: "Choose from Library")) { showLibrary = true }
                Button(String(localized: "Cancel"), role: .cancel) {}
            }
            .fullScreenCover(isPresented: $showCamera, onDismiss: {
                if let image = capturedImage {
                    capturedImage = nil
                    onAddImage(image)
                }
            }) {
                CameraImagePicker { image in capturedImage = image }
                    .ignoresSafeArea()
            }
            .photosPicker(
                isPresented: $showLibrary,
                selection: $libraryItems,
                maxSelectionCount: max(1, Self.maxPhotos - parts.count),
                matching: .images
            )
            .onChange(of: libraryItems) {
                let items = libraryItems
                guard !items.isEmpty else { return }
                libraryItems = []
                Task { @MainActor in
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                            onAddImage(image)
                        }
                    }
                }
            }
        }
    }

    /// The photos of the meal, each with its own state, and the button for one more.
    @ViewBuilder private var photoSection: some View {
        Section(
            header: parts.count > 1 ? Text("Photos of the Meal") : Text("Photo"),
            footer: Text(
                "Several photos of one meal (e.g. main dish, side and dessert) are added up to one entry."
            )
        ) {
            ForEach(Array(parts.enumerated()), id: \.element.id) { offset, part in
                photoRow(part, number: offset + 1)
            }
            if parts.count < Self.maxPhotos {
                Button {
                    showSourceDialog = true
                } label: {
                    Label("Add Another Photo", systemImage: "plus.viewfinder")
                }
            }
        }
    }

    private func photoRow(_ part: MealPhotoPart, number: Int) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(uiImage: part.image)
                .resizable()
                .scaledToFill()
                .frame(width: parts.count > 1 ? 64 : 96, height: parts.count > 1 ? 64 : 96)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                if parts.count > 1 {
                    Text(String(localized: "Photo \(number)", comment: "Meal photo number")).fontWeight(.semibold)
                }
                switch part.status {
                case .analyzing:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Analyzing meal…").foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                case let .done(analysis):
                    Text(
                        "Carbs \(grams(analysis.carbs)) · Fat \(grams(analysis.fat)) · Protein \(grams(analysis.protein))"
                    )
                    .font(.footnote)
                    if !analysis.items.isEmpty {
                        Text(analysis.items.map(\.name).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                case let .failed(message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Button("Try Again") { onRetry(part.id) }
                        .font(.footnote)
                        .buttonStyle(.borderless)
                }
            }

            Spacer(minLength: 0)

            Button(role: .destructive) {
                onRemove(part.id)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Remove Photo"))
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func resultSections(_ analysis: MealPhotoAnalysis) -> some View {
        Section(header: analyzedCount > 1 ? Text("Estimate (Sum of \(analyzedCount) Photos)") : Text("Estimate")) {
            totalsRow(String(localized: "Carbs"), grams(analysis.carbs), bold: true)
            totalsRow(String(localized: "Fat"), grams(analysis.fat))
            totalsRow(String(localized: "Protein"), grams(analysis.protein))
            totalsRow(
                String(localized: "Fat-Protein Units (FPU)"),
                fpuFormatter.string(from: analysis.fpu as NSNumber) ?? "0"
            )
            HStack {
                Text("Confidence")
                Spacer()
                Text(confidenceText(analysis.confidence))
                    .foregroundStyle(analysis.confidence == .low ? Color.orange : Color.secondary)
            }
        }

        if !analysis.items.isEmpty {
            Section(header: Text("Recognized Foods")) {
                ForEach(Array(analysis.items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(item.name)
                            Spacer()
                            if let itemGrams = item.grams {
                                Text(grams(itemGrams)).foregroundStyle(.secondary)
                            }
                        }
                        Text(
                            "Carbs \(grams(item.carbs)) · Fat \(grams(item.fat)) · Protein \(grams(item.protein))"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }

        if let notes = analysis.notes {
            Section(header: Text("Notes")) {
                Text(notes).font(.footnote)
            }
        }

        Section {
            if isAnalyzing {
                Label("Wait until all photos are analyzed.", systemImage: "hourglass")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if parts.contains(where: \.isFailed) {
                Label(
                    "Photos that could not be analyzed are not counted. Try again or remove them.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .font(.footnote)
            }
            if analysis.confidence == .low {
                Label(
                    "Low confidence: weigh the meal or check the values carefully before you bolus.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .font(.footnote)
            }
            if !fatProteinEnabled, analysis.fpu >= 1 {
                Text(
                    "Fat and protein entries are turned off (Meal Settings), so only the carbs will be taken over. Consider the fat-protein units separately, for example with an extended bolus."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Text("These are estimates. Check and correct the values in the treatment screen before you bolus.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                onApply(analysis)
                dismiss()
            } label: {
                Text("Use These Values").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isAnalyzing)
        }
    }

    private var analyzedCount: Int { parts.filter { $0.analysis != nil }.count }

    private func totalsRow(_ title: String, _ value: String, bold: Bool = false) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).fontWeight(bold ? .semibold : .regular)
        }
    }

    private func confidenceText(_ confidence: MealPhotoAnalysis.Confidence) -> String {
        switch confidence {
        case .low: return String(
                localized: "mealPhoto.confidence.low",
                defaultValue: "Low",
                comment: "Meal photo analysis confidence"
            )
        case .medium: return String(
                localized: "mealPhoto.confidence.medium",
                defaultValue: "Medium",
                comment: "Meal photo analysis confidence"
            )
        case .high: return String(
                localized: "mealPhoto.confidence.high",
                defaultValue: "High",
                comment: "Meal photo analysis confidence"
            )
        }
    }
}
