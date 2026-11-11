import SwiftUI

struct StreamLayer: Identifiable {
    let id: Int
    let name: String
    let originalVisible: Bool
}

struct StreamObjectInfo: Identifiable {
    let id: String
    let name: String
    let type: String
    let layerIndex: Int
}

struct StreamObjectDetails: Identifiable {
    let id: String
    let name: String
    let type: String
    let layer: String
    let material: String
}

struct StreamLayerBrowser: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.streamLayers) { layer in
                        DisclosureGroup {
                            ForEach(model.streamObjects.filter { $0.layerIndex == layer.id }) { object in
                                Text(object.name.isEmpty ? object.type : object.name)
                                    .font(.subheadline)
                            }
                        } label: {
                            Toggle(isOn: Binding(get: { model.layerVisibility[layer.id] ?? layer.originalVisible }, set: { model.layerVisibility[layer.id] = $0 })) {
                                Text(layer.name)
                            }
                        }
                    }
                } header: {
                    Text("\(model.streamLayers.count) 个图层 · \(model.streamObjects.count) 个对象")
                }
            }
            .navigationTitle("模型图层")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
