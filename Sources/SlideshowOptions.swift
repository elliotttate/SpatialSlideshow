import SwiftUI
import CryptoKit

enum FramingMode: String, CaseIterable {
    case fill, fit
    var title: String { self == .fill ? "Fill Screen" : "Fit with Black Bars" }
}

enum MotionStyle: Int, CaseIterable {
    case varied = -1, leftToRight, rightToLeft, pushIn, pullBack, diagonal, vertical
    var title: String {
        switch self {
        case .varied: return "Varied"
        case .leftToRight: return "Left to Right"
        case .rightToLeft: return "Right to Left"
        case .pushIn: return "Push In"
        case .pullBack: return "Pull Back"
        case .diagonal: return "Diagonal"
        case .vertical: return "Vertical"
        }
    }
    func pattern(for index: Int, sourceIdentity: String) -> Int {
        guard self == .varied else { return rawValue }
        // Album shuffle changes playback order, not a photo's rendered movement.
        // Swift's Hasher is randomized between launches; SHA256 stays stable.
        return Int(SHA256.hash(data: Data(sourceIdentity.utf8)).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } % 6)
    }
}

enum PhotoVersion: String, CaseIterable {
    case current, original
    var title: String { self == .current ? "Full Quality · Latest Edits" : "Full Quality · Unedited Original" }
}

enum ExpansionBackend: String, CaseIterable {
    case appleCleanup, fluxKlein, drawThingsFlux, applePhotosExtend
    var title: String {
        switch self {
        case .appleCleanup: return "Apple Fast Clean Up"
        case .fluxKlein: return "FLUX.2 Klein · MLX"
        case .drawThingsFlux: return "FLUX · Draw Things"
        case .applePhotosExtend: return "Apple Photos Extend"
        }
    }
    var expansionDescription: String {
        switch self {
        case .appleCleanup:
            return "Experimental · Fast, local edge fill using the installed Photos models."
        case .fluxKlein:
            return "Experimental · Local generative outpainting. Allow several minutes per new photo; expanded stills are saved for reuse. Generated scenery may differ from the real scene."
        case .drawThingsFlux:
            return "Experimental · FLUX.2 Klein 4B through Draw Things, running locally. Generates a border in four steps and preserves the original photo. Expanded stills are saved for reuse; generated scenery and background focus may differ."
        case .applePhotosExtend:
            return "Research preview · Uses Apple’s online Extend service through the open Photos app. Requires the temporary SIP-disabled setup and Xcode tools. Currently enabled for the Trip album only. Expanded images are saved for reuse."
        }
    }
}

struct SlideshowOptions: View {
    @ObservedObject var model: SlideshowModel

    private var expansionAmount: Binding<Double> {
        Binding(get: { Double(model.expansionPercent) }, set: { model.expansionPercent = Int($0.rounded()) })
    }
    private var zoomOutAmount: Binding<Double> {
        Binding(get: { Double(model.effectiveExpansionZoomOutPercent) }, set: { model.expansionZoomOutPercent = Int($0.rounded()) })
    }
    private var motionDescription: String {
        model.motion < 0.65 ? "Subtle" : model.motion > 1.25 ? "Strong" : "Gentle"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "slider.horizontal.3").font(.title).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Slideshow Settings").font(.title2.bold())
                    Text("Make the movement, framing, and soundtrack your own.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Divider()
            ScrollView {
                VStack(spacing: 18) {
                    settingsSection("Models & Downloads", symbol: "arrow.down.circle") {
                        Text("Models are checked before playback. Missing local FLUX models download automatically. Apple Photos models are requested through macOS; if Apple requires setup in Photos, the app will explain the next step.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(model.modelSetupRunning ? "Cancel Download" : "Download / Check Models") {
                                if model.modelSetupRunning { model.cancelModelSetup() } else { model.downloadModels() }
                            }.disabled(!model.modelSetupRunning && (model.busy || model.albumPlaying))
                            if model.needsPhotosSetup { Button("Open Photos", action: model.openPhotosForModels) }
                            Spacer()
                        }
                        if model.modelSetupRunning { ProgressView().controlSize(.small) }
                        if let setup = model.modelSetupStatus {
                            Text(setup).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    settingsSection("Playback", symbol: "play.rectangle") {
                        Picker("Screen framing", selection: $model.framing) {
                            ForEach(FramingMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented)
                        Toggle("Fade between photos", isOn: $model.crossfade)
                        Text("Framing and album fades update while you play. Fades in a saved slideshow change after rebuilding.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    settingsSection("Camera Movement", symbol: "camera.viewfinder") {
                        HStack {
                            Text("Time per photo")
                            Spacer()
                            Text("\(Int(model.seconds)) seconds").monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $model.seconds, in: 3...12, step: 1)
                            .accessibilityLabel("Seconds per photo")
                        HStack {
                            Text("3D motion strength")
                            Spacer()
                            Text(motionDescription).foregroundStyle(.secondary)
                        }
                        Slider(value: $model.motion, in: 0.25...1.8, step: 0.05)
                            .accessibilityLabel("3D motion strength")
                        Text("Movement pattern").font(.subheadline)
                        VStack(spacing: 8) {
                            ForEach(0..<3, id: \.self) { row in
                                HStack(spacing: 8) {
                                    ForEach(Array(MotionStyle.allCases.dropFirst(row * 3).prefix(3)), id: \.self) { style in
                                        settingChoice(style.title, selected: model.motionStyle == style) {
                                            model.motionStyle = style
                                        }
                                    }
                                    if row == 2 {
                                        Spacer().frame(maxWidth: .infinity)
                                        Spacer().frame(maxWidth: .infinity)
                                    }
                                }
                            }
                        }
                    }
                    settingsSection("Photo Edge Expansion", symbol: "arrow.up.left.and.arrow.down.right") {
                        Toggle("Expand photo edges", isOn: $model.expandPhotoEdges)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(model.availableExpansionBackends, id: \.self) { backend in
                                settingChoice(backend.title, selected: model.expansionBackend == backend) {
                                    model.expansionBackend = backend
                                }
                            }
                        }.disabled(!model.expandPhotoEdges)
                        Text(model.expansionBackend.expansionDescription)
                            .font(.caption).foregroundStyle(.secondary)
                        if model.expansionBackend == .fluxKlein || model.expansionBackend == .drawThingsFlux {
                            Text("Required models download automatically the first time you play. No Python, Homebrew, or developer tools need to be installed. Allow about 16 GB of free space for the initial download and processing.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Setup Help", action: model.expansionBackend == .fluxKlein ? model.showKleinSetup : model.showDrawThingsSetup)
                                Spacer()
                            }
                            if model.expansionBackend == .fluxKlein {
                                DisclosureGroup("Advanced runtime settings") {
                                    HStack {
                                        Text(model.kleinPythonPath.isEmpty ? "Automatic managed runtime" : "Custom runtime selected")
                                            .font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        Button("Choose…", action: model.chooseKleinRuntime)
                                        if !model.kleinPythonPath.isEmpty { Button("Reset to Automatic", action: model.resetKleinRuntime) }
                                    }.disabled(model.modelSetupRunning)
                                }
                            }
                        }
                        HStack {
                            Text("Extra area per edge")
                            Spacer()
                            Text("\(model.expansionPercent)%").monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: expansionAmount, in: 1...20, step: 1)
                            .disabled(!model.expandPhotoEdges)
                            .accessibilityLabel("Extra area per edge")
                        Text("Keeps the original photo close in view and uses the extra area for camera movement. Larger extensions can make the edges softer.")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        HStack {
                            Text("Maximum zoom out")
                            Spacer()
                            Text("\(model.effectiveExpansionZoomOutPercent)%").monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: zoomOutAmount, in: 0...Double(model.expansionPercent * 2), step: 1)
                            .disabled(!model.expandPhotoEdges)
                            .accessibilityLabel("Maximum zoom out")
                        Text("0% keeps the original framing. Higher values let the camera show more of the expanded area, up to \(model.expansionPercent * 2)% more width and height. Motion strength also scales the effect.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    settingsSection("Album", symbol: "photo.stack") {
                        Toggle("Shuffle album", isOn: $model.shuffleAlbum)
                        Toggle("Include videos", isOn: $model.includeVideos)
                        Text("Videos play at full length. Album order and included videos update the next time you start the album.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    settingsSection("Photo Quality", symbol: "sparkles.rectangle.stack") {
                        Text("Photos source").font(.subheadline)
                        ForEach(PhotoVersion.allCases, id: \.self) { version in
                            settingChoice(version.title, selected: model.photoVersion == version) {
                                model.photoVersion = version
                            }
                        }
                        Picker("Output resolution", selection: $model.outputLongEdge) {
                            Text("1920 px · Standard").tag(1920)
                            Text("3840 px · High").tag(3840)
                        }.pickerStyle(.segmented)
                        Text("Both source options download the full-quality photo from iCloud when needed. Prepared photos are kept for future plays; higher resolution needs more storage.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    settingsSection("Sound & Music", symbol: "music.note") {
                        Toggle("Play video sound", isOn: $model.videoSound)
                        Text("Turn video sound off to hear only your music during album videos.")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        MusicSettings(music: model.music)
                    }
                    DisclosureGroup("Experimental research tools") {
                        Toggle("Show Apple Photos Extend research backend", isOn: $model.showResearchBackends)
                        Text("Requires a separate developer setup and is restricted to the Trip research album. This is not part of normal slideshow setup.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(24)
            }
            Divider()
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.hasPendingRenderSettings ? "Changes ready for the next play" : "Settings save automatically")
                        .font(.subheadline.weight(.medium))
                    Text(model.hasPendingRenderSettings
                         ? "Restart to use the new motion, expansion, album, or quality settings now."
                         : "Motion, expansion, album, and quality settings apply on the next play or build.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if model.hasPendingRenderSettings {
                    Button(model.albumTitle != nil ? "Restart Album" : "Rebuild Slideshow", action: model.applyRenderSettings)
                        .buttonStyle(.borderedProminent)
                }
            }.padding(20)
        }
        .frame(width: 650, height: 760)
    }

    // Each choice is a single accessible button. Explicit labels also keep
    // decorative checkmarks out of screen-reader announcements.
    private func settingChoice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                Text(title)
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity).padding(.vertical, 3)
        }
        .tint(selected ? .accentColor : .secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private func settingsSection<Content: View>(_ title: String, symbol: String,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol).font(.headline)
            VStack(alignment: .leading, spacing: 12) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
    }
}

private struct MusicSettings: View {
    @ObservedObject var music: MusicPlayback

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(music.hasSelection ? music.currentTrackName : "No music selected")
                        .lineLimit(1).help(music.currentTrackName)
                    Text(music.hasSelection ? music.playlistDescription : "Choose one or more local audio files.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose Music…", action: music.chooseMusic)
            }
            if music.hasSelection {
                HStack {
                    Button(music.isPlaying ? "Pause Music" : "Play Music", action: music.toggle)
                    Button("Next Track", action: music.nextTrack).disabled(music.tracks.count < 2)
                    Button("Stop", action: music.stop)
                    Spacer()
                    Button("Remove", action: music.clear)
                }
            }
            HStack {
                Image(systemName: "speaker.fill")
                Slider(value: $music.volume, in: 0...1).accessibilityLabel("Music volume")
                Image(systemName: "speaker.wave.3.fill")
                Text("\(Int(music.volume * 100))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 38)
            }
            Toggle("Repeat music playlist", isOn: $music.loopPlaylist)
            Text("Music plays with the slideshow and is not included in saved MP4s.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = music.error {
                Text(error).font(.caption).foregroundStyle(.red)
                Button("Dismiss music error") { music.error = nil }
            }
        }
    }
}
