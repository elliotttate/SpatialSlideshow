import SwiftUI
import Photos
import UniformTypeIdentifiers

struct PhotoAlbum: Identifiable {
    let id: String
    let title: String
    let count: Int
    let collection: PHAssetCollection?
    let favorites: Bool
}

final class AlbumLibrary: ObservableObject {
    @Published var albums: [PhotoAlbum] = []
    @Published var assets: [PHAsset] = []
    @Published var selectedID: String?
    @Published var loading = false
    @Published var message: String?
    private var includeVideos = false
    private var libraryRequest = UUID()
    private var selectionRequest = UUID()
    let images = PHCachingImageManager()
    var selected: PhotoAlbum? { albums.first { $0.id == selectedID } }

    static func fetch(_ album: PhotoAlbum? = nil, includeVideos: Bool = false) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        let media = includeVideos
            ? NSPredicate(format: "mediaType IN %@", [PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue])
            : NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.predicate = album?.favorites == true
            ? NSCompoundPredicate(andPredicateWithSubpredicates: [media, NSPredicate(format: "favorite == YES")])
            : media
        if let collection = album?.collection { return PHAsset.fetchAssets(in: collection, options: options) }
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return PHAsset.fetchAssets(with: options)
    }
    func connect(includeVideos: Bool = false) {
        if self.includeVideos != includeVideos { albums = [] }
        self.includeVideos = includeVideos
        let request = UUID(); libraryRequest = request; selectionRequest = UUID()
        assets = []
        loading = true; message = nil
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] access in
            DispatchQueue.main.async {
                guard let self, self.libraryRequest == request else { return }
                guard access == .authorized || access == .limited else {
                    self.loading = false
                    self.message = "Allow Photos access for Spatial Slideshow in System Settings → Privacy & Security → Photos, then click Refresh."
                    return
                }
                self.refresh()
            }
        }
    }
    func refresh() {
        let request = UUID(); libraryRequest = request; selectionRequest = UUID()
        let includeVideos = self.includeVideos
        assets = []; loading = true; message = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var result = [PhotoAlbum(id: "all", title: includeVideos ? "All Photos & Videos" : "All Photos", count: Self.fetch(includeVideos: includeVideos).count, collection: nil, favorites: false)]
            let favorites = PhotoAlbum(id: "favorites", title: "Favorites", count: 0, collection: nil, favorites: true)
            result.append(PhotoAlbum(id: favorites.id, title: favorites.title, count: Self.fetch(favorites, includeVideos: includeVideos).count, collection: nil, favorites: true))
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
            let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)
            collections.enumerateObjects { collection, _, _ in
                let provisional = PhotoAlbum(id: collection.localIdentifier, title: collection.localizedTitle ?? "Untitled album", count: 0, collection: collection, favorites: false)
                result.append(PhotoAlbum(id: provisional.id, title: provisional.title, count: Self.fetch(provisional, includeVideos: includeVideos).count, collection: collection, favorites: false))
            }
            DispatchQueue.main.async {
                guard let self, self.libraryRequest == request else { return }
                self.albums = result
                self.select(self.selectedID.flatMap { selected in result.contains { $0.id == selected } ? selected : nil } ?? "all")
            }
        }
    }
    func select(_ id: String) {
        selectedID = id; assets = []; loading = true
        let request = UUID(); selectionRequest = request
        let libraryRequest = self.libraryRequest
        let includeVideos = self.includeVideos
        guard let album = selected else { loading = false; return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var items: [PHAsset] = []
            Self.fetch(album, includeVideos: includeVideos).enumerateObjects { asset, _, _ in items.append(asset) }
            DispatchQueue.main.async {
                guard let self, self.selectionRequest == request, self.libraryRequest == libraryRequest else { return }
                self.assets = items; self.loading = false
            }
        }
    }
}

struct AlbumThumbnail: View {
    let asset: PHAsset
    let manager: PHCachingImageManager
    @State private var image: NSImage?
    @State private var request: PHImageRequestID?
    private var isVideo: Bool { asset.mediaType == .video }
    private var durationText: String {
        let seconds = asset.duration.isFinite ? max(0, Int(asset.duration.rounded())) : 0
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    private var accessibilityDescription: String {
        var text = isVideo ? "Video, duration \(durationText)" : "Photo"
        if let date = asset.creationDate { text += ", \(date.formatted(date: .abbreviated, time: .shortened))" }
        return text
    }
    var body: some View {
        ZStack {
            Color.gray.opacity(0.12)
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else {
                Image(systemName: isVideo ? "video" : "photo").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 126).clipped().clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .bottomTrailing) {
            if isVideo {
                Label(durationText, systemImage: "video.fill")
                    .font(.caption.monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .onAppear {
            let options = PHImageRequestOptions(); options.isNetworkAccessAllowed = true
            options.deliveryMode = .opportunistic; options.resizeMode = .fast
            request = manager.requestImage(for: asset, targetSize: CGSize(width: 300, height: 252), contentMode: .aspectFill, options: options) { result, _ in
                DispatchQueue.main.async { image = result }
            }
        }
        .onDisappear { if let request { manager.cancelImageRequest(request) } }
    }
}

struct AlbumBrowser: View {
    @ObservedObject var library: AlbumLibrary
    @Binding var shuffle: Bool
    @Binding var includeVideos: Bool
    let play: (String, [PHAsset]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    private var itemCount: String {
        let videos = library.assets.filter { $0.mediaType == .video }.count
        let photos = library.assets.count - videos
        let photoText = "\(photos) \(photos == 1 ? "photo" : "photos")"
        return videos == 0 ? photoText : "\(photoText), \(videos) \(videos == 1 ? "video" : "videos")"
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading) {
                Text("Photo Albums").font(.title2.bold()).padding(.top, 8)
                TextField("Find an album", text: $search).textFieldStyle(.roundedBorder)
                List {
                    ForEach(library.albums.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { album in
                        Button { library.select(album.id) } label: {
                            HStack {
                                Image(systemName: album.id == "favorites" ? "heart" : "photo.on.rectangle")
                                Text(album.title).lineLimit(2)
                                Spacer()
                                Text("\(album.count)").foregroundStyle(.secondary).monospacedDigit()
                            }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(library.selectedID == album.id ? Color.accentColor.opacity(0.2) : Color.clear)
                    }
                }.listStyle(.sidebar)
                Toggle("Include Videos", isOn: $includeVideos)
                    .help("Include full-length videos when playing an album.")
                    .accessibilityIdentifier("includeAlbumVideos")
                Button("Refresh", systemImage: "arrow.clockwise") { library.connect(includeVideos: includeVideos) }
            }.padding(16).frame(width: 250)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(library.selected?.title ?? "Your Photos Library").font(.title2.bold())
                        Text("\(itemCount) · \(shuffle ? "Shuffled playback" : "Album order")").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(isOn: $shuffle) { Label("Shuffle", systemImage: "shuffle") }
                        .toggleStyle(.button)
                        .help("Play every selected photo or video once in a new random order.")
                    Button("Play Album", systemImage: "play.fill") {
                        play(library.selected?.title ?? "Album", library.assets); dismiss()
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(library.assets.isEmpty || library.loading)
                    Button("Done") { dismiss() }
                }
                if let message = library.message {
                    ContentUnavailableView("Photos access needed", systemImage: "photo.badge.exclamationmark", description: Text(message))
                } else if library.loading { ProgressView(includeVideos ? "Loading photos and videos…" : "Loading photos…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if library.assets.isEmpty { ContentUnavailableView(includeVideos ? "No photos or videos in this album" : "No photos in this album", systemImage: "photo.on.rectangle") }
                else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                            ForEach(library.assets, id: \.localIdentifier) { asset in AlbumThumbnail(asset: asset, manager: library.images) }
                        }
                    }
                }
                Text(includeVideos
                     ? "Plays photos and full-length videos. Live Photos play as still photos. iCloud media downloads as needed."
                     : "Plays every still photo, including the still frame of Live Photos. iCloud originals download as needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(width: 1030, height: 700)
        .onAppear { library.connect(includeVideos: includeVideos) }
        .onChange(of: includeVideos) { _, value in library.connect(includeVideos: value) }
    }
}
