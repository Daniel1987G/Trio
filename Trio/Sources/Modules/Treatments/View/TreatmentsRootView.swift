import Charts
import CoreData
import LoopKitUI
import PhotosUI
import SwiftUI
import Swinject

extension Treatments {
    struct RootView: BaseView {
        enum FocusedField {
            case carbs
            case fat
            case protein
            case bolus
        }

        @FocusState private var focusedField: FocusedField?

        let resolver: Resolver

        @State var state = StateModel()

        @State private var showPresetSheet = false
        @State private var autofocus: Bool = true
        @State private var calculatorDetent = PresentationDetent.large
        @State private var pushed: Bool = false
        @State private var debounce: DispatchWorkItem?
        @State private var showFatProteinOrderBanner = false

        // Meal photo analysis
        @State private var showPhotoSourceDialog = false
        @State private var showCamera = false
        @State private var showPhotoLibrary = false
        @State private var photoPickerItems: [PhotosPickerItem] = []
        @State private var showMealPhotoSheet = false
        @State private var showMealPhotoSetupAlert = false
        /// Camera result, analyzed once the camera cover has gone (two modals cannot overlap).
        @State private var capturedMealPhoto: UIImage?

        /// Check whether the on-screen keyboard is currently up.
        @State private var isKeyboardVisible = false

        /// Que scroll target
        @State private var pendingScrollTarget: FocusedField?

        private enum Config {
            static let dividerHeight: CGFloat = 2
            static let spacing: CGFloat = 3
        }

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        private var formatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumIntegerDigits = 2
            formatter.maximumFractionDigits = 3
            return formatter
        }

        private var bolusProgressFormatter: NumberFormatter {
            let fractionDigits: Int = switch state.settingsManager.preferences.bolusIncrement {
            case 0.1: 1
            case 0.025: 3
            default: 2
            }

            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.minimum = 0
            formatter.maximumFractionDigits = fractionDigits
            formatter.minimumFractionDigits = fractionDigits
            formatter.allowsFloats = true
            formatter.roundingIncrement = Double(state.settingsManager.preferences.bolusIncrement) as NSNumber
            return formatter
        }

        private var mealFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumIntegerDigits = 3
            formatter.maximumFractionDigits = 0
            return formatter
        }

        private var gluoseFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            if state.units == .mmolL {
                formatter.maximumIntegerDigits = 2
                formatter.maximumFractionDigits = 1
            } else {
                formatter.maximumIntegerDigits = 3
                formatter.maximumFractionDigits = 0
            }
            return formatter
        }

        private var fractionDigits: Int {
            if state.units == .mmolL {
                return 1
            } else { return 0 }
        }

        /// Handles macro input (carb, fat, protein) in a debounced fashion.
        func handleDebouncedInput() {
            debounce?.cancel()
            debounce = DispatchWorkItem { [self] in
                Task {
                    await state.updateForecasts()
                    state.insulinCalculated = await state.calculateInsulin()
                }
            }
            if let debounce = debounce {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: debounce)
            }
        }

        @ViewBuilder private func proteinAndFat() -> some View {
            HStack {
                HStack {
                    Text("Fat")
                    TextFieldWithToolBar(
                        text: $state.fat,
                        placeholder: "0",
                        keyboardType: .numberPad,
                        numberFormatter: mealFormatter,
                        showArrows: true,
                        previousTextField: { focusedField = previousField(from: .fat) },
                        nextTextField: { focusedField = nextField(from: .fat) },
                        unitsText: String(localized: "g", comment: "Units for carbs")
                    )
                    .focused($focusedField, equals: .fat)
                }

                Divider().foregroundStyle(.primary).fontWeight(.bold).frame(width: 10)

                HStack {
                    Text("Protein")
                    TextFieldWithToolBar(
                        text: $state.protein,
                        placeholder: "0",
                        keyboardType: .numberPad,
                        numberFormatter: mealFormatter,
                        showArrows: true,
                        previousTextField: { focusedField = previousField(from: .protein) },
                        nextTextField: { focusedField = nextField(from: .protein) },
                        unitsText: String(localized: "g", comment: "Units for carbs")
                    )
                    .focused($focusedField, equals: .protein)
                }
            }
        }

        @ViewBuilder private func carbsTextField() -> some View {
            HStack {
                Text("Carbs")
                Spacer()
                TextFieldWithToolBar(
                    text: $state.carbs,
                    placeholder: "0",
                    keyboardType: .numberPad,
                    numberFormatter: mealFormatter,
                    showArrows: true,
                    previousTextField: { focusedField = previousField(from: .carbs) },
                    nextTextField: { focusedField = nextField(from: .carbs) },
                    unitsText: String(localized: "g", comment: "Units for carbs")
                )
                .focused($focusedField, equals: .carbs)
                .onChange(of: state.carbs) {
                    handleDebouncedInput()
                }
            }
        }

        /// Determines the next field to focus on based on the current focused field.
        private func nextField(from current: FocusedField) -> FocusedField? {
            // If fat/protein fields are hidden, skip them in navigation
            let showFPU = state.useFPUconversion

            switch current {
            case .fat:
                return .protein
            case .protein:
                return .bolus
            case .carbs:
                return showFPU ? .fat : .bolus
            case .bolus:
                return .carbs
            }
        }

        /// Determines the previous field to focus on based on the current focused field.
        private func previousField(from current: FocusedField) -> FocusedField? {
            let showFPU = state.useFPUconversion

            switch current {
            case .fat:
                return .carbs
            case .protein:
                return .fat
            case .carbs:
                return .bolus
            case .bolus:
                return showFPU ? .protein : .carbs
            }
        }

        /// Scrolls the currently focused input row so it stays visible above the on-screen keyboard.
        private func scrollFocusedFieldIntoView(_ field: FocusedField?, proxy: ScrollViewProxy) {
            guard let field else {
                // drop any queued target so it can't be acted on later by an unrelated keyboard appearance.
                pendingScrollTarget = nil
                return
            }

            // Fat and Protein share a single row, which is tagged with `.fat`.
            let targetID: FocusedField = (field == .protein) ? .fat : field

            if isKeyboardVisible {
                // The keyboard is already on screen (e.g. the user is tabbing between fields with the
                // arrow buttons) - there's no animation to wait for, so scroll right away.
                withAnimation {
                    proxy.scrollTo(targetID, anchor: .center)
                }
            } else {
                // Queue the target
                pendingScrollTarget = targetID
            }
        }

        /// Performs the scroll queued by `scrollFocusedFieldIntoView`
        private func handleKeyboardWillShow(_ notification: Notification, proxy: ScrollViewProxy) {
            isKeyboardVisible = true

            guard let target = pendingScrollTarget else { return }
            pendingScrollTarget = nil

            // Confirm queued target is still in focus
            let currentTarget: FocusedField? = focusedField.map { $0 == .protein ? .fat : $0 }
            guard currentTarget == target else { return }

            let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            withAnimation(.easeInOut(duration: duration)) {
                proxy.scrollTo(target, anchor: .center)
            }
        }

        /// Opens camera or library and estimates carbs, fat and protein with the configured AI provider.
        private var mealPhotoButton: some View {
            Button {
                if state.isMealPhotoConfigured {
                    showPhotoSourceDialog = true
                } else {
                    showMealPhotoSetupAlert = true
                }
            } label: {
                HStack {
                    Image(systemName: "camera.viewfinder")
                    Text("Estimate from Photo")
                    Spacer()
                    Image(systemName: "sparkles").foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
        }

        private func startMealPhotoAnalysis(_ image: UIImage) {
            state.analyzeMealPhoto(image)
            showMealPhotoSheet = true
        }

        /// Own view for Reduced Bolus / Super Bolus toggles, the recommendation readout and the Bolus field
        @ViewBuilder private var bolusSection: some View {
            if state.fattyMeals || state.sweetMeals {
                HStack(spacing: 10) {
                    if state.fattyMeals {
                        Toggle(isOn: $state.useFattyMealCorrectionFactor) {
                            Text("Reduced Bolus")
                        }
                        .toggleStyle(RadioButtonToggleStyle())
                        .font(.footnote)
                        .onChange(of: state.useFattyMealCorrectionFactor) {
                            Task {
                                state.insulinCalculated = await state.calculateInsulin()
                                if state.useFattyMealCorrectionFactor {
                                    state.useSuperBolus = false
                                }
                            }
                        }
                    }
                    if state.sweetMeals {
                        Toggle(isOn: $state.useSuperBolus) {
                            Text("Super Bolus")
                        }
                        .toggleStyle(RadioButtonToggleStyle())
                        .font(.footnote)
                        .onChange(of: state.useSuperBolus) {
                            Task {
                                state.insulinCalculated = await state.calculateInsulin()
                                if state.useSuperBolus {
                                    state.useFattyMealCorrectionFactor = false
                                }
                            }
                        }
                    }
                }
            }

            if state.iob > 0 || state.ignorePositiveIOB {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $state.ignorePositiveIOB) {
                        Text(
                            String(
                                localized: "Don't subtract IOB (\(formatter.string(from: state.iob as NSNumber) ?? "0") U)",
                                comment: "Bolus calculator: do not subtract positive insulin on board"
                            )
                        )
                    }
                    .toggleStyle(RadioButtonToggleStyle())
                    .font(.footnote)
                    .onChange(of: state.ignorePositiveIOB) {
                        Task { state.insulinCalculated = await state.calculateInsulin() }
                    }
                    if state.ignorePositiveIOB {
                        Text(
                            "Active insulin is not taken into account for this bolus. Use only if it no longer acts on this meal or correction: risk of stacking insulin and of hypoglycemia. Max IOB still applies."
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            }

            HStack {
                HStack {
                    Text("Recommendation")
                    Button(action: {
                        state.showInfo.toggle()
                    }, label: {
                        Image(systemName: "info.circle")
                    })
                        .foregroundStyle(.blue)
                        .buttonStyle(PlainButtonStyle())
                        .accessibilityLabel(Text("About the recommendation"))
                }
                Spacer()
                Button {
                    state.amount = state.insulinCalculated
                } label: {
                    HStack {
                        Text(
                            formatter
                                .string(from: Double(state.insulinCalculated) as NSNumber) ?? ""
                        )

                        Text(
                            String(
                                localized:
                                " U",
                                comment: "Unit in number of units delivered (keep the space character!)"
                            )
                        ).foregroundColor(.secondary)
                    }
                }
                .disabled(state.insulinCalculated == 0 || state.amount == state.insulinCalculated)
                .buttonStyle(.bordered).padding(.trailing, -10)
                .accessibilityLabel(Text(
                    "Use recommended bolus, "
                        + (formatter.string(from: Double(state.insulinCalculated) as NSNumber) ?? "")
                        + " " + String(localized: "units", comment: "Insulin units, spoken")
                ))
                .accessibilityHint(Text("Copies the recommended amount into the bolus field"))
            }

            HStack {
                Text("Bolus")
                Spacer()
                TextFieldWithToolBar(
                    text: $state.amount,
                    placeholder: "0",
                    textColor: colorScheme == .dark ? .white : .blue,
                    maxLength: 5,
                    numberFormatter: formatter,
                    showArrows: true,
                    previousTextField: { focusedField = previousField(from: .bolus) },
                    nextTextField: { focusedField = nextField(from: .bolus) },
                    unitsText: String(localized: "U", comment: "Units for bolus amount")
                ).focused($focusedField, equals: .bolus)
                    .onChange(of: state.amount) {
                        Task {
                            await state.updateForecasts()
                        }
                    }
            }
            .id(FocusedField.bolus)

            HStack {
                Text("External Insulin")
                Spacer()
                Toggle("", isOn: $state.externalInsulin).toggleStyle(CheckboxToggleStyle())
            }

            if !state.externalInsulin {
                extendedBolusRows
            }
        }

        /// Meal type with a pre-selected bolus strategy, and the extended bolus it may set up.
        @ViewBuilder private var extendedBolusRows: some View {
            Picker(selection: Binding(
                get: { state.mealCarbType },
                set: { state.selectMealCarbType($0) }
            )) {
                ForEach(MealCarbType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            } label: {
                Text("Meal Type")
            }
            .pickerStyle(.menu)
            .disabled(state.isExtendedBolusRunning)

            if state.mealCarbType != .standard {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.mealCarbType.examples).font(.caption).foregroundStyle(.secondary)
                    Text(state.mealCarbType.strategy).font(.footnote)
                }
            }

            HStack {
                Text("Extended Bolus")
                Spacer()
                Toggle("", isOn: $state.useExtendedBolus).toggleStyle(CheckboxToggleStyle())
            }
            .disabled(state.isExtendedBolusRunning)

            if state.isExtendedBolusRunning {
                Text("An extended bolus is already running. Stop it on the Home screen to start a new one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if state.useExtendedBolus {
                if state.extendedCoversFPU {
                    fpuRows
                } else {
                    Stepper(value: $state.extendedImmediatePercent, in: 0 ... 90, step: 10) {
                        HStack {
                            Text("Immediate Part")
                            Spacer()
                            Text("\(state.extendedImmediatePercent) %").foregroundStyle(.secondary)
                        }
                    }
                }
                Stepper(value: $state.extendedDurationMinutes, in: 30 ... 480, step: 30) {
                    HStack {
                        Text("Extended Over")
                        Spacer()
                        Text(formatHrMin(state.extendedDurationMinutes)).foregroundStyle(.secondary)
                    }
                }
                Stepper(
                    value: $state.extendedDelayMinutes,
                    in: MealCarbTypeSettings.extendedDelayRange,
                    step: MealCarbTypeSettings.extendedDelayStep
                ) {
                    HStack {
                        Text("Extended Part Starts")
                        Spacer()
                        Text(
                            state.extendedDelayMinutes == 0 ?
                                String(localized: "immediately", comment: "Extended bolus delay of 0 minutes") :
                                String(
                                    localized: "after \(formatHrMin(state.extendedDelayMinutes))",
                                    comment: "Extended bolus delay, e.g. 'after 30 m'"
                                )
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                let split = state.extendedBolusSplit
                let immediateText = formatter.string(from: split.immediate as NSNumber) ?? "0"
                let extendedText = formatter.string(from: split.extended as NSNumber) ?? "0"
                let entryCount = state.extendedCarbSchedule(from: Date()).count
                let startText = state.extendedDelayMinutes == 0 ?
                    String(localized: "immediately", comment: "Extended bolus delay of 0 minutes") :
                    String(
                        localized: "after \(formatHrMin(state.extendedDelayMinutes))",
                        comment: "Extended bolus delay, e.g. 'after 30 m'"
                    )
                Group {
                    if split.extended > 0, state.extendedCarbGrams <= 0 {
                        Text("The extended part cannot be entered as carbs without a carb ratio.")
                            .foregroundStyle(.red)
                    } else {
                        Text(
                            "Now \(immediateText) U as a bolus. The remaining \(extendedText) U are entered as \(state.extendedCarbGrams) g carbs in \(entryCount) entries over \(formatHrMin(state.extendedDurationMinutes)), starting \(startText). The loop doses for each entry when it becomes due."
                        )
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                if state.pendingExtendedCarbGrams > 0 {
                    Text(
                        "Another extended bolus is still running with \(state.pendingExtendedCarbGrams) g carbs to come. Its entries and the new ones add up; the chart shows each in its own row."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                if state.extendedCarbsMayExceedMaxCOB {
                    let maxCOBText = Formatter.integerFormatter.string(from: state.maxCOB as NSNumber) ?? "0"
                    Text(
                        "COB, the carbs still to come and this meal can add up to more than Max COB (\(maxCOBText) g). The loop then counts at most \(maxCOBText) g and doses less than planned."
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
            }
        }

        /// FPU count, the insulin for it and why fat/protein are not also entered as delayed carbs.
        @ViewBuilder private var fpuRows: some View {
            Stepper(
                value: Binding(
                    get: { state.extendedFPU },
                    set: {
                        state.extendedFPU = $0
                        state.updateExtendedDurationForFPU()
                    }
                ),
                in: 0 ... 12,
                step: 0.5
            ) {
                HStack {
                    Text("Fat-Protein Units (FPU)")
                    Spacer()
                    Text(fpuFormatter.string(from: state.extendedFPU as NSNumber) ?? "0").foregroundStyle(.secondary)
                }
            }
            let fpu = state.fpuInsulin
            if state.effectiveCarbRatio > 0 {
                Text(
                    "FPU insulin: \(state.fpuInsulinPercent) % of \(formatter.string(from: fpu.full as NSNumber) ?? "0") U = \(formatter.string(from: fpu.given as NSNumber) ?? "0") U (1 FPU like 10 g carbs, carb ratio \(formatter.string(from: state.effectiveCarbRatio as NSNumber) ?? "0") g/U). The bolus field above is given now."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                Text("No carb ratio available, the FPU insulin cannot be calculated.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if state.fat > 0 || state.protein > 0 {
                Text(
                    "Fat and protein are entered only once, as the carb entries of the extended part, so they are not covered twice."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }

        private var fpuFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = 1
            formatter.maximumFractionDigits = 1
            return formatter
        }

        var body: some View {
            ZStack(alignment: .center) {
                VStack {
                    ScrollViewReader { proxy in
                        List {
                            Section {
                                ForecastChart(state: state)
                                    .padding(.vertical)
                            }.listRowBackground(Color.chart)

                            Section {
                                mealPhotoButton

                                carbsTextField()
                                    .id(FocusedField.carbs)

                                if state.useFPUconversion {
                                    proteinAndFat()
                                        .id(FocusedField.fat)

                                    if showFatProteinOrderBanner {
                                        HStack {
                                            Image(systemName: "arrow.left.arrow.right")
                                            Text("The order of Fat and Protein inputs has changed.").font(.callout)
                                            Spacer()
                                            Button {
                                                PropertyPersistentFlags.shared.hasSeenFatProteinOrderChange = true
                                                withAnimation { showFatProteinOrderBanner = false }
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel(Text("Dismiss"))
                                        }
                                        .listRowBackground(Color.orange.opacity(0.75))
                                        .transition(.opacity)
                                    }
                                }

                                // Time
                                HStack {
                                    // Semi-hacky workaround to make sure the List renders the horizontal divider properly between the `Time` and `Note` rows within the Section
                                    HStack {
                                        Text("")
                                        Image(systemName: "clock").padding(.leading, -7)
                                    }

                                    Spacer()
                                    if !pushed {
                                        Button {
                                            pushed = true
                                        } label: { Text("Now") }.buttonStyle(.borderless).foregroundColor(.secondary)
                                            .padding(.trailing, 5)
                                    } else {
                                        Button { state.date = state.date.addingTimeInterval(-15.minutes.timeInterval) }
                                        label: { Image(systemName: "minus.circle") }.tint(.blue).buttonStyle(.borderless)
                                            .accessibilityLabel(Text("15 minutes earlier"))

                                        DatePicker(
                                            "Time",
                                            selection: $state.date,
                                            displayedComponents: [.hourAndMinute]
                                        ).controlSize(.mini)
                                            .labelsHidden()
                                            .onChange(of: state.date) { _, _ in
                                                // Trigger simulation when date changes to update forecasts for backdated carbs
                                                Task {
                                                    // `updateForecasts()` does update the `simulatedDetermination` of type `Determination?` var on the main thread, so I can use this to pass its cob value into the bolus calc manager
                                                    await state.updateForecasts()
                                                    state.insulinCalculated = await state.calculateInsulin()
                                                }
                                            }
                                        Button {
                                            state.date = state.date.addingTimeInterval(15.minutes.timeInterval)
                                        }
                                        label: { Image(systemName: "plus.circle") }.tint(.blue).buttonStyle(.borderless)
                                            .accessibilityLabel(Text("15 minutes later"))
                                    }
                                }

                                // Notes
                                HStack {
                                    Image(systemName: "square.and.pencil")
                                    TextFieldWithToolBarString(
                                        text: $state.note,
                                        placeholder: String(localized: "Note..."),
                                        maxLength: 25
                                    )
                                }
                            }.listRowBackground(Color.chart)

                            Section {
                                bolusSection
                            }.listRowBackground(Color.chart)

                            treatmentButton
                        }
                        .listSectionSpacing(sectionSpacing)
                        .onChange(of: focusedField) { _, newValue in
                            scrollFocusedFieldIntoView(newValue, proxy: proxy)
                        }
                        .onReceive(
                            Foundation.NotificationCenter.default
                                .publisher(for: UIResponder.keyboardWillShowNotification)
                        ) { notification in
                            handleKeyboardWillShow(notification, proxy: proxy)
                        }
                        .onReceive(
                            Foundation.NotificationCenter.default
                                .publisher(for: UIResponder.keyboardWillHideNotification)
                        ) { _ in
                            isKeyboardVisible = false
                            // Belt-and-suspenders alongside the staleness check in handleKeyboardWillShow:
                            // if the keyboard went away before a queued target was ever consumed, drop it.
                            pendingScrollTarget = nil
                        }
                    }
                }
                .blur(radius: state.isAwaitingDeterminationResult ? 5 : 0)

                if state.isAwaitingDeterminationResult {
                    CustomProgressView(text: progressText.displayName)
                }
            }
            .padding(.top)
            .ignoresSafeArea(edges: .top)
            .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
            .blur(radius: state.showInfo ? 3 : 0)
            .navigationTitle("Treatments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        state.hideModal()
                    } label: {
                        Text("Close")
                    }
                }
                if state.displayPresets {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: {
                            showPresetSheet = true
                        }, label: {
                            HStack {
                                Text("Presets")
                                Image(systemName: "plus")
                            }
                        })
                    }
                }
            })
            .onAppear {
                configureView {
                    state.isActive = true
                    Task { @MainActor in
                        state.insulinCalculated = await state.calculateInsulin()
                    }

                    if PropertyPersistentFlags.shared.hasSeenFatProteinOrderChange != true {
                        showFatProteinOrderBanner = true
                    }
                }
            }
            .onDisappear {
                state.isActive = false
                state.addButtonPressed = false

                // Cancel all Combine subscriptions and unregister State from broadcaster
                state.cleanupTreatmentState()
            }
            .sheet(isPresented: $state.showInfo) {
                PopupView(state: state)
            }
            .confirmationDialog(
                String(localized: "Analyze Meal Photo"),
                isPresented: $showPhotoSourceDialog,
                titleVisibility: .visible
            ) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button(String(localized: "Take Photo")) { showCamera = true }
                }
                Button(String(localized: "Choose from Library")) { showPhotoLibrary = true }
                Button(String(localized: "Cancel"), role: .cancel) {}
            }
            .fullScreenCover(isPresented: $showCamera, onDismiss: {
                if let image = capturedMealPhoto {
                    capturedMealPhoto = nil
                    startMealPhotoAnalysis(image)
                }
            }) {
                CameraImagePicker { image in
                    capturedMealPhoto = image
                }
                .ignoresSafeArea()
            }
            .photosPicker(
                isPresented: $showPhotoLibrary,
                selection: $photoPickerItems,
                maxSelectionCount: MealPhotoAnalysisSheet.maxPhotos,
                matching: .images
            )
            .onChange(of: photoPickerItems) {
                let items = photoPickerItems
                guard !items.isEmpty else { return }
                photoPickerItems = []
                Task { @MainActor in
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                            startMealPhotoAnalysis(image)
                        }
                    }
                }
            }
            .sheet(isPresented: $showMealPhotoSheet, onDismiss: {
                // closing the sheet without taking over the values discards the photos
                state.discardMealPhotos()
            }) {
                MealPhotoAnalysisSheet(
                    parts: state.mealPhotoParts,
                    combined: state.combinedMealPhotoAnalysis,
                    fatProteinEnabled: state.useFPUconversion,
                    onApply: { analysis in state.applyMealPhoto(analysis) },
                    onRetry: { id in state.retryMealPhoto(id) },
                    onRemove: { id in state.removeMealPhoto(id) },
                    onAddImage: { image in state.analyzeMealPhoto(image) }
                )
            }
            .alert(String(localized: "Meal Photo Analysis"), isPresented: $showMealPhotoSetupAlert) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: {
                Text(
                    "To estimate a meal from a photo, add an API key for Anthropic Claude, OpenAI or Google Gemini in Settings → Features → Treatments → Meal Settings → Meal Photo Analysis."
                )
            }
            .sheet(isPresented: $showPresetSheet, onDismiss: {
                showPresetSheet = false
            }) {
                MealPresetView(state: state)
            }
            .alert("Error while processing Treatment", isPresented: $state.showDeterminationFailureAlert) {
                Button("OK", role: .cancel) {
                    state.hideModal()
                }
            } message: {
                Text("\(state.determinationFailureMessage)")
            }
        }

        var progressText: ProgressText {
            switch (state.amount > 0, state.carbs > 0) {
            case (true, true):
                return .updatingIOBandCOB
            case (false, true):
                return .updatingCOB
            case (true, false):
                return .updatingIOB
            default:
                return .updatingTreatments
            }
        }

        @State private var showConfirmDialogForBolusing = false
        @State private var showZeroBolusWarning = false

        /// Continues with the regular flow: the low-glucose confirmation if needed, otherwise the treatment.
        private func proceedWithTreatment() {
            if bolusWarning.shouldConfirm {
                showConfirmDialogForBolusing = true
            } else {
                state.invokeTreatmentsTask()
            }
        }

        /// Back to the bolus field, once the sheet is gone so the keyboard can appear.
        private func focusBolusField() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                focusedField = .bolus
            }
        }

        private var bolusWarning: (shouldConfirm: Bool, warningMessage: String, color: Color) {
            let isGlucoseVeryLow = state.currentBG < 54
            let isForecastVeryLow = state.minPredBG < 54

            // Only warn when enacting a bolus via pump
            guard !state.externalInsulin, state.amount > 0 else {
                return (false, "", .primary)
            }

            let warningMessage = isGlucoseVeryLow ? String(localized: "Glucose is very low.") :
                isForecastVeryLow ? String(localized: "Glucose forecast is very low.") :
                ""

            let warningColor: Color = isGlucoseVeryLow ? .red : colorScheme == .dark ? .orange : .accentColor

            let shouldConfirm = state.confirmBolus && (isGlucoseVeryLow || isForecastVeryLow)

            return (shouldConfirm, warningMessage, warningColor)
        }

        var treatmentButton: some View {
            let shouldDisplayBolusProgress = bolusInProgressForEntry

            var treatmentButtonBackground = Color(.systemBlue)
            if limitExceeded {
                treatmentButtonBackground = Color(.systemRed)
            } else if disableTaskButton {
                treatmentButtonBackground = Color(.systemGray)
            }

            return Section {
                if shouldDisplayBolusProgress {
                    bolusInProgressView
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                } else {
                    Button {
                        if state.amount == 0 {
                            showZeroBolusWarning = true
                        } else {
                            proceedWithTreatment()
                        }
                    } label: {
                        HStack {
                            taskButtonLabel
                        }
                        .font(.headline)
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 35)
                    }
                    .disabled(disableTaskButton)
                    .listRowBackground(treatmentButtonBackground)
                    .shadow(radius: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .glassActionSheet(
                        Text(bolusWarning.warningMessage + " Bolus \(state.amount.description) U?"),
                        isPresented: $showConfirmDialogForBolusing,
                        actions: [
                            GlassSheetAction(
                                verbatim: bolusWarning.warningMessage
                                    .isEmpty ? String(localized: "Enact Bolus") :
                                    String(localized: "Ignore Warning and Enact Bolus"),
                                role: bolusWarning.warningMessage.isEmpty ? nil : .destructive
                            ) {
                                state.invokeTreatmentsTask()
                            }
                        ]
                    )
                }
            } header: {
                if !bolusWarning.warningMessage.isEmpty {
                    Text(bolusWarning.warningMessage)
                        .textCase(nil)
                        .font(.subheadline)
                        .foregroundColor(bolusWarning.color)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, -22)
                }
            }
            .glassActionSheet(
                Text("The bolus to deliver is 0 U."),
                message: state.insulinCalculated > 0 ?
                    Text("Recommended: \(state.insulinCalculated.description) U") : nil,
                isPresented: $showZeroBolusWarning,
                actions: [
                    GlassSheetAction("Continue without Bolus") {
                        proceedWithTreatment()
                    },
                    GlassSheetAction("Back to Bolus Field") {
                        focusBolusField()
                    }
                ],
                onCancel: { focusBolusField() },
                tint: .red
            )
        }

        /// Card-style in-progress visualizer matching Home's `bolusView` look:
        /// insulin-tinted background, cross.vial.fill icon, "Bolusing" + "X of Y U" text,
        /// xmark.app cancel, gradient progress bar overlaid at the bottom.
        @ViewBuilder private var bolusInProgressView: some View {
            let progress = state.bolusProgress ?? 0
            let bolusTotal = state.lastPumpBolus?.bolus?.amount as Decimal?
            let bolusFraction = (bolusTotal ?? 0) * progress
            let bolusString: String = {
                guard let bolusTotal = bolusTotal else { return String(localized: "Bolus In Progress...") }
                return (bolusProgressFormatter.string(from: bolusFraction as NSNumber) ?? "0")
                    + String(localized: " of ", comment: "Bolus string partial message: 'x U of y U' in home view")
                    + (Formatter.decimalFormatterWithThreeFractionDigits.string(from: bolusTotal as NSNumber) ?? "0")
                    + String(localized: " U", comment: "Insulin unit")
            }()
            let bolusLabel = state.bolusStatus == .inProgress ? String(localized: "Bolusing") : String(localized: "Initiating…")

            ZStack {
                // background card
                RoundedRectangle(cornerRadius: 15)
                    .fill(
                        colorScheme == .dark
                            ? Color(red: 0.03921568627, green: 0.133333333, blue: 0.2156862745)
                            : Color.insulin.opacity(0.2)
                    )
                    .frame(height: 56)
                    .shadow(
                        color: colorScheme == .dark
                            ? Color(red: 0.02745098039, green: 0.1098039216, blue: 0.1411764706)
                            : Color.black.opacity(0.33),
                        radius: 3
                    )

                // bolus content
                HStack {
                    Image(systemName: "cross.vial.fill")
                        .font(.system(size: 25))

                    Spacer()

                    VStack {
                        Text(bolusLabel)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(bolusString)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, 5)

                    Spacer()

                    if state.bolusStatus == .inProgress {
                        Button { state.cancelBolus() } label: {
                            Image(systemName: "xmark.app")
                                .font(.system(size: 25))
                        }.tint(Color.tabBar)
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Cancel bolus")
                    } else if state.bolusStatus == .initiating {
                        ProgressView()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.trailing, 8)
            }
            .padding(.horizontal, 10)
            .overlay(alignment: .bottom) {
                BolusProgressBar(progress: progress)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 15))
        }

        private var taskButtonLabel: some View {
            if pumpBolusLimitExceeded {
                return Text("Max Bolus of \(state.maxBolus.description) U Exceeded")
            } else if externalBolusLimitExceeded {
                return Text("Max External Bolus of \(state.maxExternal.description) U Exceeded")
            } else if carbLimitExceeded {
                return Text("Max Carbs of \(state.maxCarbs.description) g Exceeded")
            } else if fatLimitExceeded {
                return Text("Max Fat of \(state.maxFat.description) g Exceeded")
            } else if proteinLimitExceeded {
                return Text("Max Protein of \(state.maxProtein.description) g Exceeded")
            }

            // a fat/protein-only meal can have only the extended FPU part
            let hasInsulin = state.amount > 0 ||
                (!state.externalInsulin && state.extendedCoversFPU && state.extendedBolusSplit.extended > 0)
            let hasCarbs = state.carbs > 0
            let hasFatOrProtein = state.fat > 0 || state.protein > 0
            let bolusString = state.externalInsulin ? String(localized: "External Insulin") : String(localized: "Enact Bolus")

            // Note: when a pump bolus is in progress, the row is rendered by `bolusInProgressView`
            // (Home-style card), so this label's in-progress branch is intentionally absent.

            switch (hasInsulin, hasCarbs, hasFatOrProtein) {
            case (true, true, true):
                return Text("Log Meal and \(bolusString)")
            case (true, true, false):
                return Text("Log Carbs and \(bolusString)")
            case (true, false, true):
                return Text("Log FPU and \(bolusString)")
            case (true, false, false):
                return Text(state.externalInsulin ? String(localized: "Log External Insulin") : String(localized: "Enact Bolus"))
            case (false, true, true):
                return Text("Log Meal")
            case (false, true, false):
                return Text("Log Carbs")
            case (false, false, true):
                return Text("Log FPU")
            default:
                return Text("Continue Without Treatment")
            }
        }

        private var pumpBolusLimitExceeded: Bool {
            !state.externalInsulin && state.amount > state.maxBolus
        }

        private var externalBolusLimitExceeded: Bool {
            state.externalInsulin && state.amount > state.maxExternal
        }

        private var carbLimitExceeded: Bool {
            state.carbs > state.maxCarbs
        }

        private var fatLimitExceeded: Bool {
            state.fat > state.maxFat
        }

        private var proteinLimitExceeded: Bool {
            state.protein > state.maxProtein
        }

        private var limitExceeded: Bool {
            pumpBolusLimitExceeded || externalBolusLimitExceeded || carbLimitExceeded || fatLimitExceeded || proteinLimitExceeded
        }

        private var bolusInProgressForEntry: Bool {
            // .initiating covers pumps that take a few seconds before reporting progress
            (state.bolusProgress != nil || state.bolusStatus == .initiating) &&
                state.amount > 0 && !state.externalInsulin
        }

        private var disableTaskButton: Bool {
            bolusInProgressForEntry || state.addButtonPressed || limitExceeded
        }
    }

    struct DividerDouble: View {
        var body: some View {
            VStack(spacing: 2) {
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(.gray.opacity(0.65))
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(.gray.opacity(0.65))
            }
            .frame(height: 4)
            .padding(.vertical)
        }
    }

    struct DividerCustom: View {
        var body: some View {
            Rectangle()
                .frame(height: 1)
                .foregroundColor(.gray.opacity(0.65))
                .padding(.vertical)
        }
    }
}
