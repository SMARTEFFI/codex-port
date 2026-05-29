import CodexPortCore
import SwiftUI

struct RemoteFileBrowserView: View {
    let store: RemoteFileBrowserStore?
    let fallbackPath: String
    let fallbackEntries: [RemoteDirectoryEntry]
    let onSelectWorkspace: (String) -> Void

    @State private var newDirectoryName = ""
    @State private var pathInput: String
    @State private var currentPath: String
    @State private var entries: [RemoteDirectoryEntry]
    @State private var roots: [String]
    @State private var errorMessage: String?

    init(
        store: RemoteFileBrowserStore?,
        fallbackPath: String = "~",
        fallbackEntries: [RemoteDirectoryEntry] = [],
        onSelectWorkspace: @escaping (String) -> Void = { _ in }
    ) {
        self.store = store
        self.fallbackPath = fallbackPath
        self.fallbackEntries = fallbackEntries
        self.onSelectWorkspace = onSelectWorkspace
        _pathInput = State(initialValue: fallbackPath)
        _currentPath = State(initialValue: fallbackPath)
        _entries = State(initialValue: fallbackEntries)
        _roots = State(initialValue: [fallbackPath])
    }

    var body: some View {
        List {
            Section("入口") {
                ForEach(roots, id: \.self) { root in
                    Button {
                        jumpToPath(root)
                    } label: {
                        Label(root, systemImage: root == roots.first ? "house" : "clock")
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("当前位置") {
                Text(currentPath)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }

            Section("跳转路径") {
                HStack {
                    TextField("绝对路径", text: $pathInput)
                        .font(.callout.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        let path = pathInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !path.isEmpty else { return }
                        jumpToPath(path)
                    } label: {
                        Image(systemName: "arrow.right.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("跳转路径")
                }
            }

            Section("创建目录") {
                HStack {
                    TextField("目录名", text: $newDirectoryName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        let name = newDirectoryName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        createDirectory(name)
                        newDirectoryName = ""
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("创建目录")
                }
            }

            Section("目录") {
                if entries.isEmpty {
                    ContentUnavailableView("空目录", systemImage: "folder")
                } else {
                    ForEach(entries, id: \.path) { entry in
                        Button {
                            if entry.kind == .directory {
                                openDirectory(entry.path)
                            }
                        } label: {
                            Label(entry.name, systemImage: entry.kind == .directory ? "folder" : "doc")
                        }
                        .disabled(entry.kind != .directory)
                    }
                }
            }

            Section {
                Button {
                    onSelectWorkspace(currentPath)
                } label: {
                    Label("在此目录新建会话", systemImage: "plus.bubble")
                }
            }
        }
        .navigationTitle("浏览目录")
        .task {
            guard let store else { return }
            do {
                try await store.loadInitialDirectory()
                currentPath = store.currentPath
                pathInput = store.currentPath
                entries = store.entries
                roots = store.roots
            } catch {
                errorMessage = String(describing: error)
            }
        }
        .alert("目录操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func openDirectory(_ path: String) {
        guard let store else {
            currentPath = path
            entries = fallbackEntries.filter { $0.path.hasPrefix(path) }
            return
        }
        Task {
            do {
                try await store.openDirectory(path)
                currentPath = store.currentPath
                pathInput = store.currentPath
                entries = store.entries
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    private func jumpToPath(_ path: String) {
        guard let store else {
            currentPath = path
            pathInput = path
            entries = fallbackEntries.filter { $0.path.hasPrefix(path) }
            return
        }
        Task {
            do {
                try await store.jumpToPath(path)
                currentPath = store.currentPath
                pathInput = store.currentPath
                entries = store.entries
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    private func createDirectory(_ name: String) {
        guard let store else { return }
        Task {
            do {
                try await store.createDirectory(named: name)
                try await store.openDirectory(store.currentPath)
                currentPath = store.currentPath
                pathInput = store.currentPath
                entries = store.entries
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }
}

#Preview {
    NavigationStack {
        RemoteFileBrowserView(
            store: nil,
            fallbackPath: "~",
            fallbackEntries: [
                RemoteDirectoryEntry(name: "Projects", path: "~/Projects", kind: .directory),
                RemoteDirectoryEntry(name: "README.md", path: "~/README.md", kind: .file),
            ]
        )
    }
}
