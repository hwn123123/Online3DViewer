import SwiftUI

struct ModelLibraryView: View {
    @ObservedObject var model: ViewerModel
    @State private var query = ""
    @State private var deleting: LibraryItem?
    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 280), spacing: 14)]
    private var filtered: [LibraryItem] {
        model.libraryItems.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("最近打开").font(.title2.bold())
                    Spacer()
                    Text("\(model.libraryItems.count) 个模型").font(.subheadline).foregroundStyle(.secondary)
                }
                if model.storageBusy {
                    ProgressView("正在整理存储…").frame(maxWidth: .infinity).padding(.vertical, 32)
                } else if model.libraryItems.isEmpty {
                    ContentUnavailableView {
                        Label("还没有模型", systemImage: "cube.transparent")
                    } description: {
                        Text("导入本地模型，随时打开查看。\n模型保存在这台设备上。")
                    } actions: {
                        Button("导入模型") { model.showingImporter = true }
                            .buttonStyle(.borderedProminent).disabled(model.baseURL == nil || model.isLoading)
                    }.padding(.vertical, 25)
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(filtered) { item in
                            ModelLibraryCard(item: item, thumbnail: model.thumbnailURL(item),
                                open: { model.openLibraryItem(item.id) },
                                clearCache: { model.clearCache(for: item.id) }, delete: { deleting = item })
                                .disabled(model.isLoading)
                        }
                    }
                }
                DisclosureGroup {
                    LazyVGrid(columns: columns, spacing: 10) {
                        sample("GLB · 头盔", "DamagedHelmet.glb")
                        sample("STL · 茶壶", "utah_teapot.stl")
                        sample("FBX · 人物", "Y_Bot.fbx")
                        sample("Rhino · 3DM", "RhinoLogo.3dm")
                        sample("STEP · 零件", "as1_pe_203.stp")
                        sample("IFC · 建筑", "haus.ifc")
                    }.padding(.top, 12)
                } label: {
                    Label("内置示例", systemImage: "cube").font(.subheadline.weight(.medium))
                }.disabled(model.baseURL == nil || model.isLoading || model.storageBusy)
                Text("每次选择一个模型，可同时选择它的材质、贴图和 BIN 等配套文件，也可选择 ZIP 文件。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(18)
        }
        .background(Color(.systemGroupedBackground))
        .searchable(text: $query, prompt: "搜索模型名称")
        .confirmationDialog("删除模型？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let item = deleting {
                Button("删除 \(item.name)", role: .destructive) { model.deleteItem(item); deleting = nil }
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { Text("将删除 App 内的模型副本和缓存，导入前的原始文件不会受影响。") }
    }

    private func sample(_ title: String, _ name: String) -> some View {
        Button { model.openSample(name) } label: {
            Text(title).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
}

private struct ModelLibraryCard: View {
    let item: LibraryItem
    let thumbnail: URL?
    let open: () -> Void
    let clearCache: () -> Void
    let delete: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Color(.tertiarySystemFill)
                    if let thumbnail, let image = UIImage(contentsOfFile: thumbnail.path) {
                        Image(uiImage: image).resizable().scaledToFit().id(item.thumbnailRevision)
                    } else {
                        Image(systemName: "cube.transparent").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
                    }
                }.frame(height: 145).clipped()
                VStack(alignment: .leading, spacing: 7) {
                    Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    HStack {
                        Text((item.name as NSString).pathExtension.uppercased()).font(.caption2.weight(.semibold))
                        Spacer(minLength: 2)
                        Text(ViewerModel.size(item.sourceBytes)).font(.caption)
                    }.foregroundStyle(.secondary)
                    Text(item.lastOpenedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开 \(item.name)")
        .accessibilityIdentifier("model-card-\(item.id)")
        .overlay(alignment: .topTrailing) {
            Menu {
                Button("打开模型", systemImage: "cube", action: open)
                Button("清理缓存", systemImage: "arrow.triangle.2.circlepath", action: clearCache)
                Button("删除模型", systemImage: "trash", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold)).frame(width: 32, height: 32)
                    .background(.regularMaterial, in: Circle()).padding(8)
            }.accessibilityLabel("\(item.name) 的更多操作")
        }
    }
}

struct ModelStorageView: View {
    @ObservedObject var model: ViewerModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("模型数量", value: "\(model.libraryItems.count)")
                    LabeledContent("模型文件", value: ViewerModel.size(model.sourceBytes))
                    LabeledContent("缓存占用", value: ViewerModel.size(model.cacheBytes))
                }
                Section {
                    Button("清理全部缓存", role: .destructive) { confirmingClear = true }
                        .disabled(model.storageBusy || model.cacheBytes == 0).accessibilityIdentifier("clear-all-cache")
                    if model.storageBusy { ProgressView("正在清理…") }
                } footer: {
                    Text("清理缓存会保留模型文件。再次打开时会重新生成显示数据。")
                }
                Section {
                    NavigationLink("开源许可") { NativeLicensesView() }
                }
            }
            .navigationTitle("存储管理").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { model.refreshStorage() }
            .confirmationDialog("清理全部缓存？", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("清理缓存", role: .destructive) { model.clearCache() }
                Button("取消", role: .cancel) {}
            } message: { Text("模型文件和缩略图会保留，下次打开需要重新处理。") }
        }
    }
}

private struct NativeLicensesView: View {
    private let root = Bundle.main.resourceURL!.appendingPathComponent("WebAssets")
    private let licenses = [
        ("Online3DViewer", "LICENSE.md"),
        ("CAD 读取器及 Rust 依赖", "CAD_RUST_NOTICES.txt"),
        ("openNURBS", "OPENNURBS_LICENSE.txt"),
        ("ufbx", "UFBX_LICENSE.txt"),
        ("cgltf", "CGLTF_LICENSE.txt"),
        ("Draco", "DRACO_NATIVE_LICENSE.txt"),
        ("OpenSKP", "OPENSKP_LICENSE.txt"),
        ("网页组件", "THIRD_PARTY_NOTICES.txt")
    ]
    var body: some View {
        List {
            Section {
                ForEach(licenses, id: \.1) { item in
                    NavigationLink(item.0) {
                        ScrollView {
                            Text((try? String(contentsOf: root.appendingPathComponent(item.1), encoding: .utf8)) ?? "许可文件无法读取")
                                .font(.caption.monospaced()).textSelection(.enabled).padding()
                        }.navigationTitle(item.0).navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
            Section {
                ShareLink(item: root.appendingPathComponent("acadrust-app-source.tar.gz")) {
                    Label("导出 CAD 读取器对应源码", systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text("acadrust 0.6.8 · MPL-2.0。源码包含此 App 使用的读取器及本地修改。")
            }
        }.navigationTitle("开源许可").navigationBarTitleDisplayMode(.inline)
    }
}
