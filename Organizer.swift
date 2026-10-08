import SwiftUI
import AppKit
import CryptoKit
import Darwin

struct Move: Codable, Identifiable {
    var id: String { source }
    let source: String
    let destination: String
    let category: String
}
struct FileIdentity: Codable, Equatable {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let digest: String
}
struct UndoEntry: Codable { let move: Move; let identity: FileIdentity; var committed: Bool }
struct Journal: Codable { let version: Int; let root: String; let bookmark: Data?; var entries: [UndoEntry] }
enum SortMode: String, CaseIterable {
    case date = "依日期"
    case type = "系統預設（依檔案類型）"
}
enum FileDateKind: String, CaseIterable {
    case created = "建立日期"
    case modified = "最後修改日期"
}
struct Organizer {
    static let fm = FileManager.default
    static func category(_ ext: String) -> String {
        switch ext.lowercased() {
        case "pdf", "doc", "docx", "txt", "rtf", "pages", "md": return "文件"
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "tiff": return "圖片"
        case "mp4", "mov", "mkv", "avi", "webm": return "影片"
        case "mp3", "wav", "m4a", "aac", "flac": return "音訊"
        case "zip", "rar", "7z", "tar", "gz": return "壓縮檔"
        case "dmg", "pkg": return "安裝檔"
        case "xls", "xlsx", "csv", "numbers", "ppt", "pptx", "key": return "表格與簡報"
        default: return "其他"
        }
    }
    static func dateName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    static func validateFolder(_ folder: URL) throws {
        if fm.fileExists(atPath: folder.path) {
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw NSError(domain: "Organizer", code: 1, userInfo: [NSLocalizedDescriptionKey: "「\(folder.lastPathComponent)」已存在但不是一般資料夾，請先重新命名。"])
            }
        }
    }
    static func plan(_ root: URL, mode: SortMode = .date, name: String = "", dateKind: FileDateKind = .created, folderOverrides: [String: String] = [:], assignments: [String: String] = [:], extraGroups: [String] = []) throws -> [Move] {
        let customName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard customName.isEmpty || (!customName.hasPrefix(".") && !customName.contains("/") && !customName.contains(":") && !customName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) && customName.utf8.count <= 255) else {
            throw NSError(domain: "Organizer", code: 4, userInfo: [NSLocalizedDescriptionKey: "資料夾名稱不可用句點開頭、包含 /、: 或控制字元，且不可超過 255 位元組。"])
        }
        let base = customName.isEmpty ? root : root.appendingPathComponent(customName, isDirectory: true)
        try validateFolder(base)
        let entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
        var reserved = Set<String>()
        var folderOwners: [String: String] = [:]
        for group in extraGroups {
            let renamed = (folderOverrides[group] ?? group).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !renamed.isEmpty, !renamed.hasPrefix("."), !renamed.contains("/"), !renamed.contains(":"), renamed.utf8.count <= 255, !renamed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw NSError(domain: "Organizer", code: 5, userInfo: [NSLocalizedDescriptionKey: "新資料夾名稱無效。"])
            }
            let normalized = renamed.precomposedStringWithCanonicalMapping.lowercased()
            if let owner = folderOwners[normalized], owner != group {
                throw NSError(domain: "Organizer", code: 6, userInfo: [NSLocalizedDescriptionKey: "資料夾名稱重複：\(renamed)。"])
            }
            folderOwners[normalized] = group
            try validateFolder(base.appendingPathComponent(renamed, isDirectory: true))
        }
        return try entries.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.compactMap { file in
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  !["download", "crdownload", "part", "partial", "tmp"].contains(file.pathExtension.lowercased()) else { return nil }
            var group: String
            if mode == .date {
                let fileDate = dateKind == .created ? values.creationDate : values.contentModificationDate
                group = fileDate.map(dateName) ?? "日期不明"
            } else {
                group = category(file.pathExtension)
            }
            group = assignments[file.path] ?? group
            let renamed = (folderOverrides[group] ?? group).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !renamed.isEmpty && !renamed.hasPrefix(".") && !renamed.contains("/") && !renamed.contains(":") && renamed.utf8.count <= 255 && !renamed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw NSError(domain: "Organizer", code: 5, userInfo: [NSLocalizedDescriptionKey: "「\(group)」的新名稱無效，請輸入一般資料夾名稱。"])
            }
            let normalized = renamed.precomposedStringWithCanonicalMapping.lowercased()
            if let owner = folderOwners[normalized], owner != group {
                throw NSError(domain: "Organizer", code: 6, userInfo: [NSLocalizedDescriptionKey: "兩個分類資料夾不能使用相同名稱：\(renamed)。"])
            }
            folderOwners[normalized] = group
            let cat = customName.isEmpty ? renamed : customName + "/" + renamed
            let folder = base.appendingPathComponent(renamed, isDirectory: true)
            try validateFolder(folder)
            var target = folder.appendingPathComponent(file.lastPathComponent)
            var suffix = 2
            while fm.fileExists(atPath: target.path) || reserved.contains(target.path) {
                let stem = file.deletingPathExtension().lastPathComponent
                let ext = file.pathExtension.isEmpty ? "" : "." + file.pathExtension
                target = folder.appendingPathComponent("\(stem) (\(suffix))\(ext)")
                suffix += 1
            }
            reserved.insert(target.path)
            return Move(source: file.path, destination: target.path, category: cat)
        }
    }
    static func failure(_ text: String) -> NSError {
        NSError(domain: "Organizer", code: 10, userInfo: [NSLocalizedDescriptionKey: text])
    }
    static func identity(_ url: URL) throws -> FileIdentity {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw failure("檔案已變更或不是一般檔案。") }
        let before = try fm.attributesOfItem(atPath: url.path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        let after = try fm.attributesOfItem(atPath: url.path)
        guard (before[.systemFileNumber] as? NSNumber) == (after[.systemFileNumber] as? NSNumber),
              (before[.size] as? NSNumber) == (after[.size] as? NSNumber),
              (before[.modificationDate] as? Date) == (after[.modificationDate] as? Date) else {
            throw failure("檔案正在變動，請稍後再試。")
        }
        return FileIdentity(device: (after[.systemNumber] as! NSNumber).uint64Value,
            inode: (after[.systemFileNumber] as! NSNumber).uint64Value,
            size: (after[.size] as! NSNumber).uint64Value,
            digest: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    static func canonicalPath(_ url: URL) -> String {
        if let resolved = url.path.withCString({ realpath($0, nil) }) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { return url.path }
        return canonicalPath(parent) + "/" + url.lastPathComponent
    }
    static func validatePath(_ url: URL, root: URL) throws {
        let base = canonicalPath(root)
        let path = canonicalPath(url)
        guard path.hasPrefix(base + "/"), path != base else { throw failure("目的位置超出選取資料夾，操作已停止。") }
        var parent = url.standardizedFileURL.deletingLastPathComponent()
        while canonicalPath(parent) != base {
            try validateFolder(parent)
            let next = parent.deletingLastPathComponent()
            guard next.path != parent.path else { throw failure("資料夾路徑無效。") }
            parent = next
        }
        try validateFolder(root)
    }
    // Atomic, same-volume move that never replaces an existing destination.
    static func safeMove(_ source: URL, _ destination: URL) throws {
        let result = source.path.withCString { src in destination.path.withCString { dst in
            renameatx_np(AT_FDCWD, src, AT_FDCWD, dst, UInt32(RENAME_EXCL))
        } }
        guard result == 0 else { throw failure("無法搬移檔案（\(String(cString: strerror(errno))))；未覆蓋目的地檔案。") }
    }
    static var journalURL: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DownloadOrganizer/undo-v2.json")
    }
    static func save(_ journal: Journal) throws {
        try fm.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
    }
    static func execute(_ moves: [Move], root: URL, bookmark: Data? = nil) throws {
        guard !moves.isEmpty else { return }
        var journal = Journal(version: 2, root: canonicalPath(root), bookmark: bookmark, entries: [])
        for move in moves {
            let source = URL(fileURLWithPath: move.source)
            let destination = URL(fileURLWithPath: move.destination)
            try validatePath(source, root: root); try validatePath(destination, root: root)
            guard canonicalPath(source.deletingLastPathComponent()) == canonicalPath(root) else { throw failure("來源不在選取資料夾第一層。") }
            let fingerprint = try identity(source)
            let folder = destination.deletingLastPathComponent()
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try validatePath(destination, root: root)
            guard !fm.fileExists(atPath: destination.path) else { throw failure("目的地已出現同名檔案，請重新預覽。") }
            journal.entries.append(UndoEntry(move: move, identity: fingerprint, committed: false))
            try save(journal)
            do {
                guard try identity(source) == fingerprint else { throw failure("來源檔案已變更。") }
                try safeMove(source, destination)
            } catch {
                journal.entries.removeLast()
                try save(journal)
                throw error
            }
            journal.entries[journal.entries.count - 1].committed = true
            try save(journal)
        }
    }
    static func undo(authorizedRoot: URL? = nil) throws -> Int {
        var journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        guard journal.version == 2 else { throw failure("復原紀錄版本不受支援。") }
        let root: URL
        var access = false
        if let authorizedRoot {
            root = authorizedRoot
            guard canonicalPath(root) == journal.root else { throw failure("請選取上次整理的原始資料夾。") }
        } else if let bookmark = journal.bookmark {
            var stale = false
            root = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale)
            access = root.startAccessingSecurityScopedResource()
            guard canonicalPath(root) == journal.root else { throw failure("原資料夾位置已變更，請先恢復原位置。") }
        } else { root = URL(fileURLWithPath: journal.root) }
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        var restored = 0
        for index in journal.entries.indices.reversed() {
            let entry = journal.entries[index]
            let source = URL(fileURLWithPath: entry.move.source)
            let destination = URL(fileURLWithPath: entry.move.destination)
            do {
                try validatePath(source, root: root); try validatePath(destination, root: root)
                guard canonicalPath(source.deletingLastPathComponent()) == canonicalPath(root) else { throw failure("復原來源路徑無效。") }
                if fm.fileExists(atPath: source.path), (try? identity(source)) == entry.identity {
                    // Also handles a crash after undo succeeded but before its checkpoint.
                    journal.entries.remove(at: index); try save(journal); continue
                }
                guard !fm.fileExists(atPath: source.path), try identity(destination) == entry.identity else { continue }
                try safeMove(destination, source)
                restored += 1
                journal.entries.remove(at: index)
                try save(journal)
            } catch { continue }
        }
        if !journal.entries.isEmpty { throw failure("已復原 \(restored) 個檔案；\(journal.entries.count) 個項目因檔案變更、同名衝突或存取問題而保留，未強行搬移。") }
        return restored
    }
    static var canUndo: Bool {
        guard let data = try? Data(contentsOf: journalURL), let j = try? JSONDecoder().decode(Journal.self, from: data) else { return false }
        return !j.entries.isEmpty
    }

}

@MainActor final class Model: ObservableObject {
    @Published var root: URL?
    var rootBookmark: Data?
    var scopedRoot: URL?
    @Published var moves: [Move] = []
    @Published var dateKind: FileDateKind = .created
    @Published var mode: SortMode = .type
    @Published var folderName = ""
    @Published var selected = Set<String>()
    @Published var previewing = false
    @Published var currentStep = 1
    @Published var openedGroup: String?
    @Published var planValid = true
    @Published var folderOverrides: [String: String] = [:]
    @Published var originalMoves: [Move] = []
    @Published var extraGroups: [String] = []
    @Published var assignments: [String: String] = [:]
    @Published var newFolderName = ""
    @Published var deletingGroup: String?
    @Published var confirmingDelete = false
    func groupFor(_ move: Move) -> String {
        assignments[move.id] ?? URL(fileURLWithPath: move.destination).deletingLastPathComponent().lastPathComponent
    }
    func addFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { status = "請輸入新資料夾名稱。"; return }
        let key = "custom-" + UUID().uuidString
        extraGroups.append(key); folderOverrides[key] = name
        refresh()
        if planValid { newFolderName = ""; openedGroup = key }
        else { extraGroups.removeAll { $0 == key }; folderOverrides.removeValue(forKey: key); planValid = true }
    }
    func moveFiles(_ ids: [String], to group: String) -> Bool {
        guard groups.contains(group), planValid else { return false }
        let valid = ids.filter { id in selected.contains(id) && originalMoves.contains(where: { $0.id == id }) }
        guard !valid.isEmpty else { return false }
        let previous = assignments
        for id in valid { assignments[id] = group }
        refresh()
        if !planValid { assignments = previous; refresh(); return false }
        openedGroup = group
        return true
    }
    var groups: [String] {
        Array(Set(originalMoves.filter { selected.contains($0.id) }.map { URL(fileURLWithPath: $0.destination).deletingLastPathComponent().lastPathComponent }).union(extraGroups)).sorted()
    }
    func files(in group: String) -> [Move] {
        let ids = Set(originalMoves.filter { groupFor($0) == group }.map(\.id))
        return selectedMoves.filter { ids.contains($0.id) }
    }
    func deleteGroup(_ group: String) {
        guard groups.contains(group) else { return }
        let affected = Set(originalMoves.filter { selected.contains($0.id) && groupFor($0) == group }.map(\.id))
        let oldAssignments = assignments
        let oldExtras = extraGroups
        let oldNames = folderOverrides
        // Remove manual placement and let the original classification rule decide again.
        assignments = assignments.filter { !affected.contains($0.key) && $0.value != group }
        extraGroups.removeAll { $0 == group }
        folderOverrides.removeValue(forKey: group)
        refresh()
        if !planValid {
            assignments = oldAssignments; extraGroups = oldExtras; folderOverrides = oldNames
            refresh(); status = "無法重新分配，已保留原資料夾。請先修正資料夾名稱或目的地衝突。"
            return
        }
        openedGroup = groups.first
        status = "已移除預覽資料夾，\(affected.count) 個檔案已依整理規則重新分配。" + (groups.contains(group) ? "原始分類仍有檔案，因此保留原始名稱的分類資料夾。" : "")
    }
    func groupName(_ group: String) -> Binding<String> {
        Binding(get: { self.folderOverrides[group] ?? group }, set: { self.folderOverrides[group] = $0; self.refresh() })
    }
    var selectedMoves: [Move] { moves.filter { selected.contains($0.id) } }
    func selection(for move: Move) -> Binding<Bool> {
        Binding(get: { self.selected.contains(move.id) }, set: { checked in
            if checked { self.selected.insert(move.id) } else { self.selected.remove(move.id) }
        })
    }
    @Published var status = "選擇下載資料夾，先看看整理後的樣子。"
    @Published var undoAvailable = Organizer.canUndo
    @Published var confirming = false
    func select() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        panel.prompt = "選擇資料夾"
        if panel.runModal() == .OK, let url = panel.url {
            // NSOpenPanel grants access for this app session.
            // Session access comes from NSOpenPanel; avoid brittle persistent bookmark creation
            // in locally signed test builds. Undo explicitly asks for the original folder.
            let bookmark: Data? = nil
            scopedRoot?.stopAccessingSecurityScopedResource()
            scopedRoot = nil
            rootBookmark = bookmark
            currentStep = 1; root = url; selected = []; moves = []; folderOverrides = [:]; extraGroups = []; assignments = [:]; refresh()

        }
    }

    func refresh() {
        guard let root else { return }
        do {
            let previousIDs = Set(moves.map(\.id))
            originalMoves = try Organizer.plan(root, mode: mode, name: folderName, dateKind: dateKind)
            moves = try Organizer.plan(root, mode: mode, name: folderName, dateKind: dateKind, folderOverrides: folderOverrides, assignments: assignments, extraGroups: extraGroups)
            let currentIDs = Set(moves.map(\.id))
            selected = selected.intersection(currentIDs).union(currentIDs.subtracting(previousIDs))
            status = moves.isEmpty ? "沒有需要整理的檔案。" : "找到 \(moves.count) 個檔案，請勾選要整理的項目。"
        }
        catch { status = error.localizedDescription; planValid = false; return }
        planValid = true
    }
    func organize() {
        guard let root, planValid else { return }
        do {
            let fresh = try Organizer.plan(root, mode: mode, name: folderName, dateKind: dateKind, folderOverrides: folderOverrides, assignments: assignments, extraGroups: extraGroups)
            guard fresh.map(\.destination) == moves.map(\.destination), fresh.map(\.source) == moves.map(\.source) else { refresh(); status = "資料夾內容已變更，請重新檢查預覽。"; return }
            let chosen = selectedMoves
            guard !chosen.isEmpty else { return }
            let count = chosen.count
            try Organizer.execute(chosen, root: root, bookmark: rootBookmark)
            for group in extraGroups {
                let custom = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
                let base = custom.isEmpty ? root : root.appendingPathComponent(custom)
                let target = base.appendingPathComponent((folderOverrides[group] ?? group).trimmingCharacters(in: .whitespacesAndNewlines))
                try Organizer.validateFolder(base); try Organizer.validateFolder(target)
                try Organizer.fm.createDirectory(at: target, withIntermediateDirectories: true)
            }
            refresh(); previewing = false; status = "完成！已整理 \(count) 個檔案。"
        } catch { currentStep = 2; refresh(); status = "整理停止：" + error.localizedDescription }
        undoAvailable = Organizer.canUndo
    }
    func undo() {
        do {
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: Organizer.journalURL))
            var authorized = root.flatMap { Organizer.canonicalPath($0) == journal.root ? $0 : nil }
            if authorized == nil {
                // A user selection is a reliable fallback when a persistent bookmark is unavailable.
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true; panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.message = "請選取上次整理的原始資料夾，以授權復原。"
                panel.directoryURL = URL(fileURLWithPath: journal.root)
                panel.prompt = "授權復原"
                guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
                guard Organizer.canonicalPath(selectedURL) == journal.root else {
                    status = "選取的資料夾不同，未執行復原。請選取：" + journal.root
                    return
                }
                authorized = selectedURL
            }
            guard let authorized else { return }
            // The current folder or a fresh NSOpenPanel selection already grants session access.
            let count = try Organizer.undo(authorizedRoot: authorized)
            refresh(); status = "已復原 \(count) 個檔案。"
        } catch { status = error.localizedDescription }
        undoAvailable = Organizer.canUndo
    }

}
enum Design {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.38, green: 0.76, blue: 0.68, alpha: 1)
            : NSColor(srgbRed: 0.12, green: 0.48, blue: 0.43, alpha: 1)
    })
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static func icon(for path: String) -> String {
        switch Organizer.category(URL(fileURLWithPath: path).pathExtension) {
        case "圖片": return "photo"
        case "影片": return "film"
        case "音訊": return "waveform"
        case "壓縮檔": return "archivebox"
        case "安裝檔": return "shippingbox"
        case "表格與簡報": return "chart.bar.doc.horizontal"
        default: return "doc.text"
        }
    }
}
struct StepBar: View {
    let currentStep: Int
    private let titles = ["選擇與設定", "預覽與調整", "確認整理"]
    var body: some View {
        HStack(spacing: 12) {
            ForEach(1...3, id: \.self) { step in
                if step > 1 {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                Label("\(step)  \(titles[step - 1])", systemImage: "\(step).circle.fill")
                    .foregroundStyle(step == currentStep ? Design.accent : Color.secondary)
                    .accessibilityLabel("步驟 \(step)：\(titles[step - 1])\(step == currentStep ? "，目前步驟" : "")")
            }
        }.font(.callout.weight(.medium))
    }
}
struct ContentView: View {
    @StateObject var model = Model()
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage()).resizable().scaledToFit().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("檔案整理器").font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("讓散落的檔案，找到自己的位置。").foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: model.select) { Label("選擇資料夾", systemImage: "folder.badge.plus") }
                    .controlSize(.large)
            }
            StepBar(currentStep: model.currentStep)
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("整理規則", systemImage: "slider.horizontal.3").font(.headline)
                    Picker("方式", selection: $model.mode) {
                        ForEach(SortMode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                    }.onChange(of: model.mode) { _, _ in model.currentStep = 1; model.refresh() }
                    if model.mode == .date {
                        Picker("日期", selection: $model.dateKind) {
                            ForEach(FileDateKind.allCases, id: \.self) { kind in Text(kind.rawValue).tag(kind) }
                        }.onChange(of: model.dateKind) { _, _ in model.currentStep = 1; model.refresh() }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Divider().frame(height: 85)
                VStack(alignment: .leading, spacing: 10) {
                    Label("統整資料夾", systemImage: "folder").font(.headline)
                    TextField("資料夾名稱（可留白）", text: $model.folderName)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: model.folderName) { _, _ in model.refresh() }
                    Text("留白則直接整理在來源資料夾內。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(20).background(Design.card, in: RoundedRectangle(cornerRadius: 16))
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("待整理檔案").font(.headline)
                    if let root = model.root {
                        Text(root.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    } else {
                        Text("選擇來源資料夾，開始整理。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.root != nil { Button("重新掃描", action: model.refresh) }
                Button("全選") { model.selected = Set(model.moves.map(\.id)) }.disabled(model.moves.isEmpty)
                Button("取消全選") { model.selected.removeAll() }.disabled(model.selected.isEmpty)
            }
            ZStack {
                Table(model.moves) {
                    TableColumn("選取") { move in
                        Toggle("整理 \(URL(fileURLWithPath: move.source).lastPathComponent)", isOn: model.selection(for: move)).labelsHidden()
                    }.width(45)
                    TableColumn("檔案") { move in
                        Label(URL(fileURLWithPath: move.source).lastPathComponent, systemImage: Design.icon(for: move.source))
                    }
                    TableColumn("類型") { move in Text(Organizer.category(URL(fileURLWithPath: move.source).pathExtension)).foregroundStyle(.secondary) }.width(95)
                    TableColumn("整理後位置") { move in Text(move.category + "/" + URL(fileURLWithPath: move.destination).lastPathComponent).foregroundStyle(.secondary) }
                }.clipShape(RoundedRectangle(cornerRadius: 12))
                if model.moves.isEmpty {
                    ContentUnavailableView(model.root == nil ? "從一個資料夾開始" : "目前沒有待整理檔案", systemImage: "tray", description: Text(model.root == nil ? "選擇下載項目或其他資料夾，再挑選要整理的檔案。" : "可重新掃描，或選擇其他資料夾。"))
                        .allowsHitTesting(false)
                }
            }.frame(minHeight: 200)
            HStack(spacing: 8) {
                Image(systemName: model.planValid ? "info.circle" : "exclamationmark.circle").foregroundStyle(Design.accent)
                Text(model.status).font(.callout).textSelection(.enabled)
            }
            Divider()
            HStack {
                Button(action: model.undo) { Label("復原上次整理", systemImage: "arrow.uturn.backward") }.disabled(!model.undoAvailable)
                Spacer()
                Text("已選 \(model.selectedMoves.count) / \(model.moves.count)").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                Button { model.currentStep = 2; model.previewing = true } label: { Label("預覽整理結果", systemImage: "arrow.right") }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.selectedMoves.isEmpty || !model.planValid)
            }
            Text("僅整理第一層檔案，同名檔案自動加編號；確認前不會搬移檔案。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(28).frame(minWidth: 900, minHeight: 730)
            .background(Design.canvas).tint(Design.accent)
            .sheet(isPresented: $model.previewing, onDismiss: { if model.currentStep == 2 { model.currentStep = 1 } }) { FolderPreview(model: model) }
    }
}

struct FolderPreview: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("整理結果預覽").font(.system(size: 26, weight: .bold, design: .rounded))
                    StepBar(currentStep: model.currentStep)
                }
                Spacer()
                Label("尚未搬移", systemImage: "checkmark.shield")
                    .font(.callout.weight(.medium)).foregroundStyle(Design.accent)
                    .padding(10).background(Design.accent.opacity(0.10), in: Capsule())
            }
            Text("這是預計整理的內容，尚未建立資料夾或移動檔案。點選資料夾查看檔案；把右側檔案拖到左側資料夾即可重新分配，也能新增與改名。")
                .foregroundStyle(.secondary)
            HStack {
                Text("大資料夾")
                TextField("可留白，直接整理在原資料夾", text: $model.folderName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: model.folderName) { _, _ in model.refresh() }
            }
            HStack {
                TextField("為新資料夾命名…", text: $model.newFolderName).textFieldStyle(.roundedBorder)
                Button(action: model.addFolder) { Label("新增資料夾", systemImage: "plus") }
            }
            HStack(alignment: .top, spacing: 18) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.groups, id: \.self) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                Button { model.openedGroup = group } label: {
                                    Label("\(model.folderOverrides[group] ?? group) · \(model.files(in: group).count) 個檔案", systemImage: "folder.fill")
                                }.buttonStyle(.borderless)
                                HStack {
                                    TextField("資料夾名稱", text: model.groupName(group)).textFieldStyle(.roundedBorder)
                                        .accessibilityLabel("重新命名 \(group)")
                                    Button {
                                        model.deletingGroup = group
                                        model.confirmingDelete = true
                                    } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).foregroundStyle(.red)
                                    .help("刪除資料夾並重新分配檔案")
                                    .accessibilityLabel("刪除 \(model.folderOverrides[group] ?? group)")
                                }
                            }
                            .dropDestination(for: String.self, action: { ids, _ in return model.moveFiles(ids, to: group) })
                            .padding(14).background(model.openedGroup == group ? Design.accent.opacity(0.12) : Design.card, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }.frame(width: 290)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if let group = model.openedGroup, model.groups.contains(group) {
                        Text(model.folderOverrides[group] ?? group).font(.headline)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(model.files(in: group)) { move in
                                    HStack {
                                        Image(systemName: Design.icon(for: move.source)).font(.title3).foregroundStyle(Design.accent).frame(width: 32)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(URL(fileURLWithPath: move.source).lastPathComponent)
                                            Text(move.category + "/" + URL(fileURLWithPath: move.destination).lastPathComponent).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Menu {
                                            ForEach(model.groups, id: \.self) { target in
                                                Button(model.folderOverrides[target] ?? target) { _ = model.moveFiles([move.id], to: target) }
                                            }
                                        } label: { Image(systemName: "folder.badge.arrow.right") }
                                        .help("移到資料夾")
                                    }.padding(14).background(Design.card, in: RoundedRectangle(cornerRadius: 12))
                                        .contentShape(Rectangle()).draggable(move.id)
                                }
                                if model.files(in: group).isEmpty {
                                    Text("資料夾目前是空的，可將檔案拖到左側這個資料夾。").foregroundStyle(.secondary).padding()
                                }
                            }
                        }

                    } else {
                        ContentUnavailableView("選擇資料夾", systemImage: "folder", description: Text("點選左側任一分類查看內容。"))
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(model.status).font(.callout).foregroundStyle(model.planValid ? Color.secondary : Color.red)
            HStack {
                Button("返回勾選檔案") { model.currentStep = 1; model.previewing = false }
                Spacer()
                Text("\(model.groups.count) 個資料夾 · \(model.selectedMoves.count) 個檔案").foregroundStyle(.secondary)
                Button("開始整理") { model.currentStep = 3; model.confirming = true }.buttonStyle(.borderedProminent)
                    .controlSize(.large).disabled(!model.planValid || model.selectedMoves.isEmpty)
            }
        }.padding(28).frame(width: 1020, height: 720).background(Design.canvas).tint(Design.accent)
        .alert("刪除這個預覽資料夾？", isPresented: $model.confirmingDelete) {
            Button("取消", role: .cancel) {}
            Button("刪除並重新分配", role: .destructive) {
                if let group = model.deletingGroup { model.deleteGroup(group) }
                model.deletingGroup = nil
            }
        } message: {
            Text("裡面的檔案會依目前整理規則重新分配，不會刪除實際檔案或資料夾。若原始分類仍有檔案，會重新顯示該分類。")
        }
        .alert("整理這 \(model.selectedMoves.count) 個檔案？", isPresented: $model.confirming) {
            Button("取消", role: .cancel) { model.currentStep = 2 }
            Button("開始整理") { model.organize() }
        } message: { Text("勾選的檔案將依「\(model.mode.rawValue)」移到預覽中的位置，未勾選的留在原處。這次整理會取代上次的復原紀錄。") }
    }
}

@main struct DownloadOrganizerApp: App {
    var body: some Scene { WindowGroup { ContentView() }.windowStyle(.titleBar) }
}
