import SwiftUI
import UIKit

/// Progress of a meal photo analysis in the treatment screen.
enum MealPhotoState {
    case idle
    case analyzing(UIImage)
    case result(UIImage, MealPhotoAnalysis)
    case failed(UIImage?, String)

    var image: UIImage? {
        switch self {
        case .idle: return nil
        case let .analyzing(image),
             let .result(image, _): return image
        case let .failed(image, _): return image
        }
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

/// Shows the analysis and lets the user take over the estimate into the treatment fields.
struct MealPhotoAnalysisSheet: View {
    let photoState: MealPhotoState
    /// Fat and protein can only be entered when the FPU conversion is enabled.
    let fatProteinEnabled: Bool
    let onApply: (MealPhotoAnalysis) -> Void
    let onRetry: () -> Void
    @Environment(\.dismiss) private var dismiss

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
                if let image = photoState.image {
                    Section {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }

                switch photoState {
                case .idle:
                    EmptyView()

                case .analyzing:
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Analyzing meal…")
                        }
                    }

                case let .failed(_, message):
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("Try Again", action: onRetry)
                    }

                case let .result(_, analysis):
                    resultSections(analysis)
                }
            }
            .navigationTitle("Meal Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder private func resultSections(_ analysis: MealPhotoAnalysis) -> some View {
        Section(header: Text("Estimate")) {
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
        }
    }

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
