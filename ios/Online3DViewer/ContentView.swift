import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: ViewerModel
    @State private var showingLayers = false
    @State private var showingStorage = false
    @State private var showingCoverage = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                if let url = model.baseURL {
                    WebViewer(model: model, url: url, sessionID: model.webViewID)
                        .id(model.webViewID)
                        .opacity(model.showingLibrary ? 0 : 1)
                        .allowsHitTesting(!model.showingLibrary && !model.isLoading)
                        .accessibilityHidden(model.showingLibrary || model.isLoading)
                }
                if !model.showingLibrary && model.isLoading {
                    Color.black.opacity(0.08)
                        .overlay(alignment: .top) {
                            Text("模型准备完成后即可旋转、缩放和选择")
                                .font(.footnote.weight(.medium)).padding(10)
                                .background(.regularMaterial, in: Capsule()).padding(.top, 12)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("模型正在准备，请等待完成后再操作")
                        .accessibilityIdentifier("model-loading-guard")
                }
                if model.showingLibrary { ModelLibraryView(model: model) }
                if model.baseURL == nil && !model.showingLibrary { ProgressView("正在启动查看器…") }
            }
            .navigationTitle(model.showingLibrary ? "模型库" : model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !model.showingLibrary {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { model.returnToLibrary() } label: { Label("模型库", systemImage: "square.grid.2x2") }
                            .accessibilityIdentifier("show-library")
                    }
                    if !model.streamLayers.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { showingLayers = true } label: { Label("图层", systemImage: "square.3.layers.3d") }
                                .disabled(model.isLoading)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.showingImporter = true } label: { Label("导入模型", systemImage: "plus") }
                        .disabled(model.baseURL == nil || model.isLoading || model.storageBusy)
                        .accessibilityIdentifier("open-model")
                }
                if model.showingLibrary {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingStorage = true } label: { Label("存储管理", systemImage: "internaldrive") }
                            .disabled(model.isLoading || model.storageBusy)
                            .accessibilityIdentifier("storage-management")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: { Label("设置", systemImage: "gearshape") }
                        .disabled(model.isLoading || model.storageBusy)
                        .accessibilityIdentifier("viewer-settings")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !model.showingLibrary || model.isLoading {
                    // A status change must not resize the canvas and restart a paged frame.
                    VStack(spacing: 0) {
                        if let progress = model.loadProgress {
                            ModelLoadingView(progress: progress, cancel: model.cancelLoading)
                        } else if let text = model.statusText {
                            Text(text).font(.footnote).lineLimit(3).padding(.horizontal,18)
                            if !model.coverageIssues.isEmpty || !model.cadDisplayWarnings.isEmpty || !model.missingFiles.isEmpty {
                                Button("查看显示说明") { showingCoverage = true }
                                    .font(.footnote).padding(.top,4).accessibilityIdentifier("cad-coverage-issues")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity).frame(height: 112)
                    .background(.regularMaterial)
                }
            }
            .sheet(isPresented: $showingStorage) { ModelStorageView(model: model) }
            .sheet(isPresented: $showingSettings) { ViewerSettingsView(model: model) }
            .sheet(isPresented: $showingLayers) { StreamLayerBrowser(model: model) }
            .sheet(isPresented: $showingCoverage) {
                NavigationStack {
                    List {
                        if !model.missingFiles.isEmpty {
                            Section("缺少的配套文件") {
                                ForEach(Array(model.missingFiles.enumerated()), id: \.offset) { _, name in
                                    Text(name).textSelection(.enabled)
                                }
                                Text("可返回模型库，重新选择模型及其材质、贴图或 BIN 等配套文件；如果文件位于子文件夹，请保持原目录结构并尝试打包成 ZIP 后导入。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        if !model.coverageIssues.isEmpty {
                            Section("未显示内容") { ForEach(model.coverageIssues, id: \.self) { Text($0) } }
                        }
                        if !model.cadDisplayWarnings.isEmpty {
                            Section("显示提示") { ForEach(model.cadDisplayWarnings, id: \.self) { Text($0) } }
                        }
                        Section { Text("原始模型文件不会被修改。").foregroundStyle(.secondary) }
                    }.navigationTitle("显示说明").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingCoverage = false } } }
                }
            }
            .sheet(item: $model.selectedObject) { object in
                NavigationStack {
                    Form {
                        LabeledContent("名称", value: object.name.isEmpty ? "未命名对象" : object.name)
                        LabeledContent("类型", value: object.type)
                        LabeledContent("图层", value: object.layer)
                        LabeledContent("材质", value: object.material)
                    }.navigationTitle("对象属性").navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { model.selectedObject = nil }
                            }
                        }
                }.presentationDetents([.medium, .large])
            }
            .fileImporter(isPresented: $model.showingImporter, allowedContentTypes: [.data, .content], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): model.importFiles(urls)
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError { model.error = "无法选择文件：\(error.localizedDescription)" }
                }
            }
            .alert("无法完成操作", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                if model.canReimportAfterError {
                    Button("重新选择文件") { model.error = nil; model.canReimportAfterError = false; model.showingImporter = true }
                }
                Button("确定", role: .cancel) { model.error = nil; model.canReimportAfterError = false }
            } message: { Text(model.error ?? "") }
        }
    }
}

private struct ViewerSettingsView: View {
    @ObservedObject var model: ViewerModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingStorage = false

    var body: some View {
        NavigationStack {
            Form {
                Section("查看器") {
                    Picker("背景", selection: $model.preferences.background) {
                        Text("白色").tag("light")
                        Text("深色").tag("dark")
                    }.pickerStyle(.menu).accessibilityIdentifier("setting-background")
                    Picker("旋转方式", selection: $model.preferences.navigation) {
                        Text("自由旋转").tag("free")
                        Text("固定向上方向").tag("fixed")
                    }.pickerStyle(.menu).accessibilityIdentifier("setting-navigation")
                    Picker("视角投影", selection: $model.preferences.projection) {
                        Text("透视").tag("perspective")
                        Text("正交").tag("orthographic")
                    }.pickerStyle(.menu).accessibilityIdentifier("setting-projection")
                    Toggle("查看时保持屏幕常亮", isOn: $model.preferences.keepAwake)
                        .accessibilityIdentifier("setting-keep-awake")
                }
                Section {
                    Picker("显示内存", selection: $model.preferences.memory) {
                        Text("自动").tag("automatic")
                        Text("节省内存").tag("economy")
                    }.pickerStyle(.menu).accessibilityIdentifier("setting-memory")
                } footer: {
                    Text("节省内存会减少显示缓存，大模型旋转时可能需要等待。设备内存紧张时仍会自动保护。")
                }
                Section("文件与存储") {
                    LabeledContent("模型数量", value: "\(model.libraryItems.count)")
                    LabeledContent("模型文件", value: ViewerModel.size(model.sourceBytes))
                    LabeledContent("显示缓存", value: ViewerModel.size(model.cacheBytes))
                    Button("管理存储和开源许可") { showingStorage = true }
                        .accessibilityIdentifier("settings-storage")
                }
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $showingStorage) { ModelStorageView(model: model) }
            .task { model.refreshStorage() }
        }
    }
}

private struct ModelLoadingView: View {
    let progress: ModelLoadProgress
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(progress.title).font(.subheadline.weight(.semibold))
                        if let fraction = progress.fraction { Text("\(Int(fraction * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                    if !progress.detail.isEmpty { Text(progress.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength: 0)
                Button("取消", action: cancel).buttonStyle(.bordered).accessibilityIdentifier("cancel-loading")
            }
            if let fraction = progress.fraction { ProgressView(value: fraction) }
            else { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 18).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }
}
