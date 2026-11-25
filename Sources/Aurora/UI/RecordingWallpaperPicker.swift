import SwiftUI

struct RecordingWallpaperPicker: View {
    @ObservedObject var library: WallpaperLibrary
    let selection: WallpaperItem?
    let select: (WallpaperItem) -> Void
    @State private var folders: [[WallpaperItem]] = []
    @State private var open = false
    @State private var query = ""

    var body: some View {
        Button {
            query = ""
            open.toggle()
        } label: {
            Label(selection?.name ?? T("从动态壁纸库选择…"), systemImage: "photo.stack")
                .lineLimit(1)
        }
        .popover(isPresented: $open) {
            VStack(alignment: .leading) {
                TextField(T("搜索壁纸"), text: $query).textFieldStyle(.roundedBorder)
                List {
                    section(T("我的壁纸"), library.items)
                    section(T("系统壁纸"), library.systemItems)
                    ForEach(folders.indices, id: \.self) { index in
                        if let first = folders[index].first {
                            section(first.url.deletingLastPathComponent().lastPathComponent, folders[index])
                        }
                    }
                }
                .listStyle(.inset)
            }.padding(10).frame(width: 290, height: 310)
                .task(id: library.randomFolders) {
                    let paths = library.randomFolders
                    let items = await readInBackground { paths.map { WallpaperLibrary.scanFolder($0) } }
                    if !Task.isCancelled { folders = items }
                }
        }
    }

    @ViewBuilder private func section(_ title: String, _ items: [WallpaperItem]) -> some View {
        let matches = items.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        if !matches.isEmpty {
            Section(title) {
                ForEach(matches) { item in
                    Button {
                        select(item)
                        open = false
                    } label: {
                        HStack {
                            Image(systemName: item.kind.symbol).frame(width: 18)
                            Text(item.name).lineLimit(1)
                            Spacer()
                            if selection?.id == item.id { Image(systemName: "checkmark") }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}
