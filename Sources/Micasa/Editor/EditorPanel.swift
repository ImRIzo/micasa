import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The editor side panel: Adjust, Crop, Looks and Export, like Licasa's EditorSidePanel.
@MainActor
struct EditorPanel: View {
    let model: ViewerModel
    @Bindable var editor: EditorSession

    var body: some View {
        VStack(spacing: 0) {
            header
            toolPicker
            Divider().opacity(0.4)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(editor.tool.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    switch editor.tool {
                    case .adjust: AdjustTool(editor: editor)
                    case .crop: CropTool(editor: editor)
                    case .looks: LooksTool(editor: editor)
                    case .export: ExportTool(model: model, editor: editor)
                    }
                }
                .padding(16)
            }
            Divider().opacity(0.4)
            footer
        }
        .background(Color(white: 0.11).opacity(0.97))
        .onHover { model.pointerOverControls = $0 }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Edit").font(.headline)
            Spacer()
            ChromeButton(systemImage: "arrow.uturn.backward", help: "Undo (⌘Z)", size: 28,
                         isEnabled: editor.canUndo) { editor.undo() }
            ChromeButton(systemImage: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", size: 28,
                         isEnabled: editor.canRedo) { editor.redo() }
            Button("Done") { model.closeEditor() }
                .disabled(editor.isCropping)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var toolPicker: some View {
        HStack(spacing: 4) {
            ForEach(EditorTool.allCases) { tool in
                Button {
                    editor.tool = tool
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tool.systemImage).font(.system(size: 14))
                        Text(tool.title).font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(editor.tool == tool ? Color.accentColor.opacity(0.35) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(tool.title) (⌃\(EditorTool.allCases.firstIndex(of: tool)! + 1))")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        HStack {
            CompareButton(editor: editor)
            Spacer()
            Button("Reset All") { editor.resetAll() }
                .disabled(editor.params.isIdentity && !editor.isCropping)
            Button("Save Copy") { model.saveEditedCopy(saveAs: false) }
                .disabled(editor.isExporting || editor.isCropping || editor.params.isIdentity)
        }
        .controlSize(.small)
        .padding(12)
    }
}

/// Shows the original while held down ("hold Original to compare").
@MainActor
struct CompareButton: View {
    let editor: EditorSession

    var body: some View {
        Label("Hold to compare", systemImage: "square.split.2x1")
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(editor.compareOriginal ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.1))
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !editor.compareOriginal { editor.compareOriginal = true } }
                    .onEnded { _ in editor.compareOriginal = false }
            )
            .help("Press and hold to see the original")
    }
}

// MARK: - Adjust

@MainActor
struct AdjustTool: View {
    let editor: EditorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PanelSection(title: "Light") {
                AdjustSlider(editor: editor, title: "Exposure", keyPath: \.exposure)
                AdjustSlider(editor: editor, title: "Contrast", keyPath: \.contrast)
                AdjustSlider(editor: editor, title: "Highlights", keyPath: \.highlights)
                AdjustSlider(editor: editor, title: "Shadows", keyPath: \.shadows)
            }
            PanelSection(title: "Color") {
                AdjustSlider(editor: editor, title: "Saturation", keyPath: \.saturation)
                AdjustSlider(editor: editor, title: "Vibrance", keyPath: \.vibrance)
                AdjustSlider(editor: editor, title: "Warmth", keyPath: \.warmth)
                AdjustSlider(editor: editor, title: "Tint", keyPath: \.tint)
            }
            PanelSection(title: "Detail") {
                AdjustSlider(editor: editor, title: "Sharpen", keyPath: \.sharpen, range: 0...1)
                AdjustSlider(editor: editor, title: "Soften", keyPath: \.soften, range: 0...0.35)
                AdjustSlider(editor: editor, title: "Vignette", keyPath: \.vignette, range: 0...1)
            }
            Button("Reset Adjustments") { editor.resetAdjustments() }
                .controlSize(.small)
                .disabled(!editor.params.hasColorAdjustments)
        }
    }
}

@MainActor
struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

@MainActor
struct AdjustSlider: View {
    let editor: EditorSession
    let title: String
    let keyPath: WritableKeyPath<EditParameters, Double>
    var range: ClosedRange<Double> = -1...1

    private var value: Binding<Double> {
        Binding(
            get: { editor.params[keyPath: keyPath] },
            set: { editor.params[keyPath: keyPath] = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(formatted)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(editor.params[keyPath: keyPath] == 0 ? .secondary : .primary)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { editor.resetValue(keyPath) }
            .help("Double-click to reset")

            Slider(value: value, in: range, onEditingChanged: { editing in
                if editing { editor.beginChange() } else { editor.endChange() }
            })
            .controlSize(.small)
        }
    }

    private var formatted: String {
        let v = editor.params[keyPath: keyPath]
        let percent = Int((v / max(abs(range.lowerBound), range.upperBound) * 100).rounded())
        if range.lowerBound < 0 { return percent > 0 ? "+\(percent)" : "\(percent)" }
        return "\(percent)"
    }
}

// MARK: - Crop

@MainActor
struct CropTool: View {
    @Bindable var editor: EditorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if editor.isCropping {
                HStack {
                    Button("Apply Crop") { editor.applyCrop() }
                        .buttonStyle(.borderedProminent)
                    Button("Cancel") { editor.cancelCrop() }
                    Spacer()
                    Button("Reset Frame") { editor.resetCropFrame() }
                }
                .controlSize(.small)
                Text(cropSizeText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                Button { editor.beginCrop() } label: {
                    Label(editor.params.hasCrop ? "Adjust Crop" : "Start Crop", systemImage: "crop")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                Text("Press C to crop, Return to apply, Esc to cancel. ⌥ + arrows nudge the frame; ⌥⇧ + arrows resize it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            PanelSection(title: "Aspect ratio") {
                FlowChips(items: CropAspect.presets, title: \.title,
                          isSelected: { $0 == editor.cropAspect }) { editor.setAspect($0) }
                HStack(spacing: 6) {
                    TextField("W", text: $editor.customAspectWidth).frame(width: 46)
                    Text(":")
                    TextField("H", text: $editor.customAspectHeight).frame(width: 46)
                    Button("Custom") {
                        if let w = Double(editor.customAspectWidth), let h = Double(editor.customAspectHeight), w > 0, h > 0 {
                            editor.setAspect(.ratio(w, h))
                        } else {
                            NSSound.beep()
                        }
                    }
                }
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            }

            PanelSection(title: "Rotate and mirror") {
                HStack(spacing: 6) {
                    Button { editor.rotate(clockwise: false) } label: { Label("Left", systemImage: "rotate.left") }
                    Button { editor.rotate(clockwise: true) } label: { Label("Right", systemImage: "rotate.right") }
                }
                HStack(spacing: 6) {
                    Button { editor.mirror(horizontal: true) } label: {
                        Label("Mirror H", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    }
                    Button { editor.mirror(horizontal: false) } label: {
                        Label("Mirror V", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                    }
                }
                Button("Reset \(editor.params.normalizedTurns * 90)° and crop") { editor.resetGeometry() }
                    .disabled(!editor.params.hasGeometry)
            }
            .controlSize(.small)
        }
    }

    private var cropSizeText: String {
        let g = editor.geometrySize
        let w = Int((editor.draftCrop.width * g.width).rounded())
        let h = Int((editor.draftCrop.height * g.height).rounded())
        return "\(w) × \(h) px"
    }
}

// MARK: - Looks

@MainActor
struct LooksTool: View {
    let editor: EditorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                Chip(title: "Original", isSelected: !editor.params.hasColorAdjustments) {
                    editor.resetAdjustments()
                }
                ForEach(Look.allCases) { look in
                    Chip(title: look.title, isSelected: editor.activeLook == look) { editor.apply(look) }
                }
            }
            Text("Every look stays fully undoable. Hold “Hold to compare” below to see the original.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Export

@MainActor
struct ExportTool: View {
    let model: ViewerModel
    @Bindable var editor: EditorSession

    var body: some View {
        let type = model.url.map {
            ImageExporter.resolvedType(editor.exportOptions.format, source: $0, hasAlpha: editor.hasAlpha)
        } ?? .jpeg
        VStack(alignment: .leading, spacing: 16) {
            PanelSection(title: "File format") {
                FlowChips(items: ImageExporter.availableFormats, title: \.title,
                          isSelected: { $0 == editor.exportOptions.format }) { editor.exportOptions.format = $0 }
                Text("Saves as \(type.preferredFilenameExtension?.uppercased() ?? type.identifier)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            PanelSection(title: "Output scale") {
                HStack {
                    Slider(value: $editor.exportOptions.scale, in: 0.1...1, step: 0.05)
                    Text("\(Int((editor.exportOptions.scale * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 40, alignment: .trailing)
                }
                let size = editor.exportPixelSize
                Text("\(Int(size.width)) × \(Int(size.height)) px")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if ImageExporter.supportsQuality(type) {
                PanelSection(title: "Quality") {
                    HStack {
                        Slider(value: $editor.exportOptions.quality, in: 0.1...1, step: 0.01)
                        Text("\(Int((editor.exportOptions.quality * 100).rounded()))")
                            .font(.caption.monospacedDigit())
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }

            HStack {
                Button("Save Copy") { model.saveEditedCopy(saveAs: false) }
                    .buttonStyle(.borderedProminent)
                Button("Save As…") { model.saveEditedCopy(saveAs: true) }
            }
            .disabled(editor.isExporting || editor.isCropping)

            if editor.isExporting {
                ProgressView().controlSize(.small)
            }
            if let status = editor.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Text("The original file is never changed. Copies keep the photo's camera metadata.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Chips

@MainActor
struct Chip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isSelected ? Color.accentColor.opacity(0.45) : Color.white.opacity(0.08))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

@MainActor
struct FlowChips<Item: Hashable>: View {
    let items: [Item]
    let title: KeyPath<Item, String>
    let isSelected: (Item) -> Bool
    let action: (Item) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 6)], spacing: 6) {
            ForEach(items, id: \.self) { item in
                Chip(title: item[keyPath: title], isSelected: isSelected(item)) { action(item) }
            }
        }
    }
}
