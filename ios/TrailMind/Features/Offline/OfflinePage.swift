import SwiftUI
import UniformTypeIdentifiers

/// Offline maps (Pages3.kt OfflinePage): download an area or a route's corridor, import an MBTiles file, and the maps
/// already on the phone with their progress, 24-hour detail and what can be done with each.
struct OfflinePage: View {
    @Environment(\.palette) private var p
    @StateObject private var model: OfflineModel
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var offline = OfflinePacks.shared
    @ObservedObject private var requests = OfflineRequests.shared
    @State private var importing = false

    init() { _model = StateObject(wrappedValue: OfflineModel(routeId: nil)) }

    /// With a route's corridor chosen (a route's "Offline map").
    init(presetRouteId: Int64?) { _model = StateObject(wrappedValue: OfflineModel(routeId: presetRouteId)) }

    var body: some View {
        PageScaffold("Offline maps") {
            staleCard
            TMCard(spacing: 8) {
                TMText("What can be offline", .label)
                HelpRow(summary: "Save licensed maps before you leave.",
                        detail: "• OS Maps areas, downloaded with your own OS Data Hub key. Overview maps stay in your pack.\n" +
                            "• Explorer 1:25k detail can be added for 24 hours, the longest OS allows. Add it on the day of the hike. TrailMind asks before it expires, and you choose whether to renew it.\n" +
                            "• Any raster MBTiles file you have the right to use (e.g. made with QGIS, MOBAC or bought).\n" +
                            "• OpenStreetMap's public tiles are never bulk-downloaded: their usage policy forbids it. Areas you browse are cached for a few days only.\n" +
                            "Zoomed in beyond what is on the phone, the map enlarges the closest zoom it has.")
            }
            downloadCard
            TMCard(spacing: 8) {
                TMText("Import an MBTiles file", .title)
                TMText("Raster PNG/JPEG/WebP MBTiles (Web Mercator, XYZ/TMS). The file is copied into app storage and works fully offline.", .caption)
                TMButton("Choose .mbtiles file", icon: .folder, style: .tonal) { importing = true }
            }
            if !model.packs.isEmpty { TMText("Your offline maps", .label) }
            ForEach(model.packs) { pack in PackCard(pack: pack, model: model) }
            TMCard(spacing: 6) {
                TMText(model.cacheBytes.map {
                    "Browse and pre-loaded tiles: \(PackPlan.mb($0)). Premium expires within 24 hours. Other browse tiles refresh after 7 days; cache limit 300 MB."
                } ?? "Calculating…", .caption)
                TMButton("Clear cache", icon: .delete, style: .text) { model.clearCache() }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { OfflinePacks.shared.importAndReport(url) }
        }
        .onAppear { model.appear() }
        .onReceive(requests.$pending.compactMap { $0 }) { request in
            // Taken on the next turn of the main loop: the request can arrive while SwiftUI builds the page.
            DispatchQueue.main.async {
                guard requests.pending == request else { return }
                requests.pending = nil
                model.take(request)
            }
        }
    }

    // MARK: Expired detail

    @ViewBuilder private var staleCard: some View {
        let now = nowMs()
        let stale = model.packs.filter { pk in
            guard pk.premiumMs > 0, offline.progress?.packId != pk.id, let detail = model.premiumExpiries[pk.id] else { return false }
            return detail.expiresAtMs <= now || !detail.complete
        }
        if !stale.isEmpty {
            TMCard(spacing: 8) {
                TMText("Download detail again", .title)
                TMText("24-hour detail is expired or partly missing. Download it again for the same area without choosing it again. The overview maps are still on the phone.", .caption)
                ForEach(stale) { pk in
                    let gone = (model.premiumExpiries[pk.id]?.expiresAtMs ?? 0) <= now
                    TMText(pk.name)
                    TMText("\(PackPlan.premiumLabel(sourceId: pk.sourceId, premiumMaxZoom: pk.premiumMaxZoom)) \(gone ? "expired" : "partly expired")", .caption)
                    FlowLayout(spacing: 8) {
                        TMButton("Download again", icon: .download, style: .tonal) { model.downloadAgain(pk, title: "Download again?") }
                    }
                }
            }
        }
    }

    // MARK: New download

    @ViewBuilder private var downloadCard: some View {
        TMCard(spacing: 10) {
            TMText("Download an area", .title)
            if let s = model.source() {
                downloadChoices(s)
            } else {
                TMBanner(message: "No source that permits offline storage is set up. Add your free OS Data Hub key in Settings (or a custom source whose licence allows offline use).")
                TMButton("Open settings", icon: .tune, style: .tonal) { Navigator.shared.push(PageRoute("settings") { SettingsPage() }) }
            }
        }
    }

    @ViewBuilder private func downloadChoices(_ s: TileSource) -> some View {
        let maxZoom = min(model.maxZoom, s.effectiveDownloadMaxZoom)
        if s.requiresKey && KotlinText.isBlank(prefs.osApiKey) { TMBanner(message: "\(s.name) needs your OS Data Hub API key (Settings).") }
        TMText("Source", .label)
        chips(model.downloadable().map { (PackPlan.chipName($0), $0.id) }, selected: s.id) { model.pickSource($0) }
        TMText("Area", .label)
        chips([("Visible map area", "")] + model.routes.prefix(PackPlan.maxRouteChoices).map { ($0.name, String($0.id)) },
              selected: model.routeId.map { String($0) } ?? "") { model.pickRoute(Int64($0)) }
        if model.routeId != nil {
            TMText("Corridor either side of the route", .label)
            chips(PackPlan.corridorOptionsM.map { (Units.distance(Double($0), imperial: prefs.imperial), String($0)) },
                  selected: String(Int(model.bufferM))) { if let m = Double($0) { model.pickBuffer(m) } }
        }
        TMText("Most detailed zoom", .label)
        chips(PackPlan.zoomOptions(s).map { (String($0), String($0)) }, selected: String(maxZoom)) { if let z = Int($0) { model.pickMaxZoom(z) } }
        TMText(PackPlan.overviewNote(s), .caption)
        if let from = s.premiumFromZoom, prefs.osPremium {
            TMText(PackPlan.premiumHeading(s), .label)
            chips(PackPlan.premiumOptions(s).map { ($0.label, String($0.zoom)) }, selected: String(model.premiumMaxZoom)) {
                if let z = Int($0) { model.pickPremium(z) }
            }
            if model.premiumMaxZoom >= from && model.count != nil { TMText(PackPlan.premiumText(model.premiumCount), .caption) }
        }
        let counted = PackPlan.countText(model.count, grid: s.grid)
        TMText(counted.text, .body, color: counted.tooMany ? p.danger : p.onSurface)
        if model.routeId != nil && model.lidarSquares > 0 {
            TMToggle(label: "Also save 1 m LiDAR near the route (England)", isOn: $prefs.packLidar)
            TMText(PackPlan.lidarText(missing: model.lidarMissing), .caption)
        }
        TMText(s.note, .caption)
        TMText(s.attribution, .caption)
        let ready = (model.count ?? 0) > 0 && !counted.tooMany
        TMButton(model.naming ? "Naming…" : "Download", icon: .download) { model.download() }
            .disabled(!ready || model.naming)
        TMText(PackDownloader.backgroundNote, .caption)
    }

    private func chips(_ items: [(String, String)], selected: String, onPick: @escaping (String) -> Void) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(items.indices, id: \.self) { i in
                TMChip(items[i].0, selected: items[i].1 == selected, wrap: true) { onPick(items[i].1) }
            }
        }
    }
}

/// One offline map (OfflinePage.packCard): name and status, source and size, progress, 24-hour detail and actions.
private struct PackCard: View {
    @Environment(\.palette) private var p
    let pack: PackMeta
    @ObservedObject var model: OfflineModel
    @ObservedObject private var offline = OfflinePacks.shared
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        let pk = pack
        let progress = offline.progress?.packId == pk.id ? offline.progress : nil
        let active = progress != nil
        let retired = TileSources.isRetired(pk.sourceId) && pk.kind == .download
        let now = nowMs()
        let detail = model.premiumExpiries[pk.id]
        let premiumUntil = detail?.expiresAtMs ?? 0
        let premiumExpired = pk.premiumMaxZoom > 0 && now >= premiumUntil
        let premiumPartial = pk.premiumMaxZoom > 0 && !premiumExpired && detail?.complete != true
        let premiumAgeing = pk.premiumMaxZoom > 0 && !premiumExpired && (detail?.toFetch ?? 0) > 0
        let detailLabel = PackPlan.premiumLabel(sourceId: pk.sourceId, premiumMaxZoom: pk.premiumMaxZoom)
        let shown = prefs.offlineMapSourceId == "pack:\(pk.id)"
        TMCard(spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                TMText(pk.name, .title).frame(maxWidth: .infinity, alignment: .leading)
                TMChip(active ? "Downloading" : PackPlan.statusLabel(pk.status.rawValue), selected: pk.status == .complete || pk.status == .ready)
            }
            TMText("\(sourceName(retired)) · zoom \(pk.minZoom)–\(pk.maxZoom) · \(PackPlan.mb(pk.bytes))", .caption)
            if pk.kind == .download {
                let done = progress?.note == nil ? (progress?.done ?? pk.tileDone) : pk.tileDone
                let failed = progress?.note == nil ? (progress?.failed ?? pk.tileFailed) : pk.tileFailed
                TMProgress(value: pk.tileTotal > 0 ? Double(done) / Double(pk.tileTotal) : 0)
                TMText(PackPlan.progressText(done: done, total: pk.tileTotal, failed: failed), .caption)
                if let progress, let note = progress.note {
                    TMText("\(note): \(progress.done) / \(progress.total)", .caption)
                }
            }
            if let message = pk.message { TMText(message, .caption, color: p.danger) }
            if pk.sourceId == TileSources.osLeisure { TMText("The map outline marks saved overview tiles, not 24-hour detail.", .caption) }
            if pk.premiumMaxZoom > 0 {
                if !premiumExpired {
                    TMText("\(detailLabel)\(premiumPartial ? " (partly loaded)" : "") until \(OfflineText.dateTime(premiumUntil))", .caption)
                } else if pk.premiumMs > 0 {
                    TMText("\(detailLabel) has expired. Download it again for another 24 hours.", .caption)
                } else {
                    TMText("\(detailLabel): not loaded", .caption)
                }
            }
            FlowLayout(spacing: 4) {
                if pk.kind == .download {
                    let again = PackPlan.againAction(status: pk.status.rawValue, premiumExpired: premiumExpired,
                                                     premiumPartial: premiumPartial, premiumAgeing: premiumAgeing)
                    if active {
                        TMButton("Pause", icon: .pause, style: .text) { PackDownloader.shared.pause() }
                    } else if let again, !retired {
                        TMButton(again, icon: again == "Resume" ? .play : .download, style: .text) {
                            model.downloadAgain(pk, title: PackPlan.againTitle(again))
                        }
                    }
                } else if shown {
                    TMButton("Remove from map", icon: .close, style: .text) { prefs.offlineMapSourceId = "" }
                } else {
                    TMButton("Use as map", icon: .map, style: .text) { OfflineFeature.showImported(pk.id) }
                }
                if let bounds = pk.bounds {
                    TMButton("Show", style: .text) { show(pk, bounds) }
                }
                TMButton("Delete", icon: .delete, style: .text) { delete(pk, active: active) }
            }
        }
    }

    private func sourceName(_ retired: Bool) -> String {
        if retired { return "Retired Japan map (delete when no longer needed)" }
        if pack.kind == .importFile { return "Imported \(pack.format.uppercased())" }
        return OfflineSources.byId(pack.sourceId, prefs, model.packs).name
    }

    /// Shows the pack's area on its own map: an imported map over the base map, a download's source as the base map.
    private func show(_ pk: PackMeta, _ bounds: BoundingBox) {
        if pk.kind == .importFile {
            prefs.offlineMapSourceId = "pack:\(pk.id)"
        } else if TileSources.builtIns().contains(where: { $0.id == pk.sourceId }) {
            prefs.baseSourceId = pk.sourceId
        } else if pk.sourceId == TileSources.custom {
            prefs.offlineMapSourceId = TileSources.custom
        }
        MapController.shared.fit(bounds)
        Navigator.shared.showMap()
    }

    private func delete(_ pk: PackMeta, active: Bool) {
        if active {
            AppModel.shared.toast("Pause the download first.")
            return
        }
        AppModel.shared.confirm("Delete offline map?", "\"\(pk.name)\" (\(PackPlan.mb(pk.bytes))) will be removed from this phone.",
                                ok: "Delete", danger: true) {
            OfflinePacks.shared.delete(pk) { model.reload() }
        }
    }
}
