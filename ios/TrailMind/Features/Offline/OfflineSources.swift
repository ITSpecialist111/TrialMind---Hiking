import Foundation

extension Prefs {
    /// iPhone only: an imported map ("pack:<id>") or the custom source ("custom") drawn over the base map, or "" for none.
    /// Android makes these the base map; the iPhone's map layers list holds the built-in maps only, so these lie over the
    /// base map at full strength, with the base map showing wherever they have no tiles.
    var offlineMapSourceId: String {
        get { UserDefaults.standard.string(forKey: "offline_map_source") ?? "" }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "offline_map_source")
        }
    }
}

/// Every tile source the offline feature deals with: the built-in maps, old maps, the user's custom source and imported
/// MBTiles files (TileSources.all/byId/custom/fromPack on Android). The `custom:` forms take the custom source already
/// read from Prefs, so they can run off the main thread.
enum OfflineSources {
    /// The custom source from Settings, or nil when none is saved or its template is not valid.
    static func custom(_ prefs: Prefs) -> TileSource? {
        custom(name: prefs.customName, template: prefs.customTemplate, attribution: prefs.customAttribution,
               maxZoom: prefs.customMaxZoom, offlineAllowed: prefs.customOfflineAllowed)
    }

    static func custom(name: String, template: String, attribution: String, maxZoom: Int, offlineAllowed: Bool) -> TileSource? {
        if KotlinText.isBlank(template) || TilePolicy.validateTemplate(template) != nil { return nil }
        return TileSources.custom(name: name, template: template, attribution: attribution,
                                  maxZoom: maxZoom.clamped(1, TilePolicy.maxZoom), offlineAllowed: offlineAllowed,
                                  bulkForbidden: TilePolicy.isBulkDownloadForbidden(template))
    }

    static func fromPack(_ p: PackMeta) -> TileSource {
        TileSources.fromPack(id: p.id, name: p.name, attribution: p.attribution, minZoom: p.minZoom, maxZoom: p.maxZoom)
    }

    static func all(custom: TileSource?, _ packs: [PackMeta]) -> [TileSource] {
        TileSources.builtIns() + TileSources.historic() + [custom].compactMap { $0 } +
            packs.filter { $0.kind == .importFile }.map(fromPack)
    }

    static func byId(_ id: String, custom: TileSource?, _ packs: [PackMeta]) -> TileSource {
        all(custom: custom, packs).first { $0.id == id } ?? TileSources.builtIns()[0]
    }

    static func byId(_ id: String, _ prefs: Prefs, _ packs: [PackMeta]) -> TileSource { byId(id, custom: custom(prefs), packs) }

    /// Sources whose terms allow storing tiles in a pack, and whose host does not forbid bulk downloads.
    static func downloadable(custom: TileSource?, _ packs: [PackMeta]) -> [TileSource] {
        all(custom: custom, packs).filter { s in
            guard let template = s.template else { return false }
            return s.offlineDownloadAllowed && !TilePolicy.isBulkDownloadForbidden(template)
        }
    }

    /// The base map on screen, as the map shows it (built-in maps only).
    static func base(_ prefs: Prefs) -> TileSource {
        TileSources.builtIns().first { $0.id == prefs.baseSourceId } ?? TileSources.builtIns()[0]
    }
}
