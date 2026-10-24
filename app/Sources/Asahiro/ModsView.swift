import AppKit
import SwiftUI
import UniformTypeIdentifiers

func chooseModArchives() -> [URL] {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = [.zip, .folder, UTType(filenameExtension: "7z") ?? .data, UTType(filenameExtension: "rar") ?? .data]
    panel.prompt = "Add"
    panel.message = "Choose mod archives (.zip, .7z, .rar) or extracted mod folders"
    return panel.runModal() == .OK ? panel.urls : []
}

enum ModStatusFilter: String, CaseIterable, Identifiable {
    case all = "All", enabled = "Enabled", disabled = "Disabled", conflicts = "Conflicts"
    var id: String { rawValue }
}

struct ModsView: View {
    @EnvironmentObject var model: LauncherModel
    let close: () -> Void
    @State private var search = ""
    @State private var status: ModStatusFilter = .all
    @State private var character: String?
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\ModInfo.name, comparator: .localizedStandard)]
    @State private var dropTargeted = false
    @State private var confirmTrash: Set<String>?

    private var characters: [(String, Int)] {
        Dictionary(grouping: model.mods.compactMap(\.character), by: { $0 })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    private var visible: [ModInfo] {
        let terms = search.lowercased().split(separator: " ").map(String.init)
        return model.mods.filter { m in
            let hay = "\(m.name) \(m.character ?? "")".lowercased()
            guard terms.allSatisfy({ hay.contains($0) }) else { return false }
            if let character, m.character != character { return false }
            switch status {
            case .all: return true
            case .enabled: return m.enabled
            case .disabled: return !m.enabled
            case .conflicts: return !m.conflicts.isEmpty
            }
        }
        .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.zzmi?.installed != true {
                notInstalled
            } else {
                filterBar
                    .padding(.horizontal, Space.xl)
                    .padding(.bottom, Space.m)
                if model.mods.isEmpty {
                    emptyState
                } else {
                    table
                    bulkBar
                }
            }
        }
        .frame(width: 860, height: 580)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                    .strokeBorder(Color.zzzYellow, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .overlay(Label("Drop to add mods", systemImage: "square.and.arrow.down").font(.system(size: 15, weight: .semibold)))
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.importMods(urls)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .task { await model.loadMods() }
        // a renamed folder gets a new id, keep the selection pointing at mods that still exist
        .onChange(of: model.mods) { _, mods in
            let ids = Set(mods.map(\.id))
            selection = selection.filter { ids.contains($0) }
        }
        .confirmationDialog(trashTitle, isPresented: Binding(get: { confirmTrash != nil }, set: { if !$0 { confirmTrash = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let ids = confirmTrash { model.trashMods(ids) }
                selection.subtract(confirmTrash ?? [])
                confirmTrash = nil
            }
        } message: {
            Text("They can be restored from the Trash in Finder.")
        }
    }

    private var trashTitle: String {
        let n = confirmTrash?.count ?? 0
        return n == 1 ? "Move this mod to the Trash?" : "Move \(n) mods to the Trash?"
    }

    private var header: some View {
        HStack(spacing: Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Mods").font(.system(size: 20, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.zzmi?.installed == true {
                Button {
                    model.importMods(chooseModArchives())
                } label: {
                    Label("Add Mods", systemImage: "plus")
                }
                .disabled(model.activity != nil)
                Button {
                    if let p = model.zzmi?.modsPath { model.reveal(p) }
                } label: {
                    Image(systemName: "folder")
                }
                .help("Show the Mods folder in Finder")
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle())
            .glassEffect(.regular.interactive(), in: Circle())
            .keyboardShortcut(.cancelAction)
            .padding(.leading, Space.xs)
        }
        .controlSize(.small)
        .padding(.horizontal, Space.xl)
        .padding(.top, 20)
        .padding(.bottom, Space.l)
    }

    private var subtitle: String {
        if let a = model.activity, a.kind == .importMod || a.kind == .zzmiInstall { return a.status }
        guard let z = model.zzmi, z.installed else { return "ZZMI is not installed yet" }
        let on = model.mods.filter(\.enabled).count
        let state = z.enabled ? "loaded when the game starts" : "mods are turned off in Settings"
        return "\(on) of \(model.mods.count) enabled · \(state)"
    }

    private var filterBar: some View {
        HStack(spacing: Space.s) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search mods and characters", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, Space.s)
            .frame(height: 28)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))

            Picker("", selection: $status) {
                ForEach(ModStatusFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .tint(.zzzYellow)

            Picker("", selection: $character) {
                Text("All characters").tag(String?.none)
                Divider()
                ForEach(characters, id: \.0) { name, count in
                    Text("\(name)  \(count)").tag(Optional(name))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .controlSize(.small)
    }

    private var table: some View {
        Table(visible, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("", value: \.enabledKey) { mod in
                Toggle("", isOn: Binding(get: { mod.enabled }, set: { model.setMods([mod.id], enabled: $0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .tint(.zzzYellow)
            }
            .width(40)

            TableColumn("Name", value: \.name, comparator: .localizedStandard) { mod in
                HStack(spacing: 6) {
                    Text(mod.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(mod.enabled ? Color.primary : Color.secondary)
                    if !mod.conflicts.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("Overrides the same parts as: \(mod.conflicts.joined(separator: ", "))")
                    }
                }
            }
            .width(min: 200, ideal: 300, max: .infinity)

            TableColumn("Character", value: \.characterKey, comparator: .localizedStandard) { mod in
                Text(mod.character ?? "—").foregroundStyle(mod.character == nil ? .tertiary : .secondary)
            }
            .width(min: 80, ideal: 110, max: 160)

            TableColumn("Size", value: \.size) { mod in
                Text(formatBytes(mod.size)).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 60, ideal: 76, max: 100)

            TableColumn("Added", value: \.modified) { mod in
                Text(mod.addedDate, format: .dateTime.day().month(.abbreviated).year())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 84, ideal: 96, max: 120)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .font(.system(size: 13))
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty {
                Button("Enable") { model.setMods(ids, enabled: true) }
                Button("Disable") { model.setMods(ids, enabled: false) }
                Divider()
                Button("Show in Finder") { model.revealMods(ids) }
                Divider()
                Button("Move to Trash…", role: .destructive) { confirmTrash = ids }
            }
        } primaryAction: { ids in
            // double click flips the clicked mods
            let on = model.mods.filter { ids.contains($0.id) }.allSatisfy(\.enabled)
            model.setMods(ids, enabled: !on)
        }
        .padding(.horizontal, Space.m)
    }

    // shown while rows are selected, acts on the whole selection
    @ViewBuilder
    private var bulkBar: some View {
        let count = selection.count
        HStack(spacing: Space.s) {
            if count > 0 {
                Text("\(count) selected")
                    .font(.system(size: 12, weight: .semibold))
                Button("Clear") { selection = [] }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Enable") { model.setMods(selection, enabled: true) }
                Button("Disable") { model.setMods(selection, enabled: false) }
                Button("Show in Finder") { model.revealMods(selection) }
                Button("Move to Trash…", role: .destructive) { confirmTrash = selection }
            } else {
                Text("\(visible.count) shown · select rows with ⌘ or ⇧ for bulk actions, ⌘A selects all")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Space.xl)
        .frame(height: 44)
        .background(.white.opacity(count > 0 ? 0.06 : 0))
        .animation(Motion.quick, value: count > 0)
    }

    private var notInstalled: some View {
        VStack(spacing: Space.m) {
            Spacer()
            Image(systemName: "puzzlepiece.extension").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("ZZMI is not installed").font(.system(size: 15, weight: .semibold))
            Text("ZZMI loads character and UI mods into the game. Asahiro downloads it from its official GitHub releases and verifies the signatures.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Install ZZMI") { model.start(.zzmiInstall) }
                .buttonStyle(.borderedProminent)
                .tint(.zzzYellow)
                .foregroundStyle(Color.zzzInk)
                .disabled(model.activity != nil)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: Space.s) {
            Spacer()
            Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 30)).foregroundStyle(.secondary)
            Text("No mods yet").font(.system(size: 15, weight: .semibold))
            Text("Drop mod archives here, or use Add Mods. Zip, 7z, rar and folders work.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
