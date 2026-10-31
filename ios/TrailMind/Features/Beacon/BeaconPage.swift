import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Beacon (AssistantPage): a briefing for a route worked out on the phone by fixed rules, the mountain forecast for its
/// high point saved for use without signal, a write-up by Apple Intelligence where the iPhone has it, and a prompt for
/// Gemma or any assistant the user trusts.
struct BeaconPage: View {
    @Environment(\.palette) private var p
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var store = Store.shared
    @StateObject private var model: BeaconModel
    @State private var aiAvailability: BeaconAI.Availability = .unsupported
    @State private var pickingStart = false
    @State private var importing = false

    /// Beacon for `routeId`, or for the route being followed (else the newest) when nil.
    init(routeId: Int64? = nil) {
        _model = StateObject(wrappedValue: BeaconModel(presetRouteId: routeId))
    }

    private static let edgeGalleryUrl = URL(string: "https://apps.apple.com/app/id6749645337")!
    private static let gpxTypes: [UTType] = [UTType("com.topografix.gpx") ?? .xml, .xml]

    var body: some View {
        PageScaffold("Beacon") {
            howItWorks
            if model.routesLoaded {
                if model.routes.isEmpty { importCard } else { routeContent }
            }
        }
        .onAppear {
            aiAvailability = BeaconAI.availability
            model.reloadRoutes(refresh: true)
        }
        .onChange(of: store.revision) { _, _ in model.reloadRoutes() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            aiAvailability = BeaconAI.availability
        }
        .sheet(isPresented: $pickingStart) {
            PaletteProvider {
                BeaconStartPicker(startMs: model.startMs) { model.startMs = $0 }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.gpxTypes) { importGpx($0) }
        .task(id: aiRequest) { await model.writeUp(aiRequest) }
    }

    /// The briefing prompt to write up with Apple Intelligence, when the iPhone has it and the user wants it.
    private var aiRequest: String? {
        guard prefs.beaconUseAppleIntelligence, aiAvailability == .available else { return nil }
        return model.briefing(prefs)?.prompt
    }

    // MARK: Sections

    private var howItWorks: some View {
        TMCard(spacing: 8) {
            Text("How this works").tm(.label, p)
            TMText("Beacon builds a briefing on-device from your route, pace settings and sunset time using fixed rules (no AI). " +
                "Only the mountain forecast needs internet, and it's saved for use without signal. " +
                "Where the iPhone has Apple Intelligence, Apple's on-device model can write the briefing up in plain words, and nothing leaves the phone. " +
                "For a write-up from Gemma, copy the prompt into Google AI Edge Gallery, which runs Gemma locally. Edge Gallery has no app-to-app API, so the prompt is copied for you to paste. " +
                "AI output can be wrong – never rely on it for safety decisions.", .caption)
            switch aiAvailability {
            case .available:
                TMToggle(label: "Write it up with Apple Intelligence", isOn: $prefs.beaconUseAppleIntelligence,
                         detail: "On this iPhone, from the offline briefing")
            case .notReady:
                TMToggle(label: "Write it up with Apple Intelligence", isOn: $prefs.beaconUseAppleIntelligence,
                         detail: "Apple Intelligence is still getting ready on this iPhone. The write-up appears once it is.")
            case .turnedOff:
                TMText("Turn on Apple Intelligence in Settings to have the briefing written up on this iPhone.", .caption)
            case .unsupported:
                EmptyView()
            }
        }
    }

    private var importCard: some View {
        TMCard(spacing: 8) {
            TMText("Import a route first", .title)
            TMButton("Import GPX", icon: .upload) { importing = true }
        }
    }

    @ViewBuilder private var routeContent: some View {
        SectionLabel("Route")
        FlowLayout(spacing: 8) {
            ForEach(model.routes.prefix(12)) { r in
                TMChip(r.name, selected: r.id == model.routeId, wrap: true) { model.select(r.id) }
            }
        }
        SectionLabel("Planned start")
        FlowLayout(spacing: 8) {
            TMChip(BeaconDaylight.plannedStart(model.startMs), selected: true) { pickingStart = true }
                .accessibilityHint("Choose the date and time you set off")
            TMChip("Now") { model.startMs = BeaconDaylight.nextQuarterHour() }
            TMChip("Tomorrow 09:00") { model.startMs = BeaconDaylight.tomorrowAt(9) }
        }
        if let d = model.data, d.meta.id == model.routeId {
            if let b = model.briefing(prefs) {
                TMText(b.startBy, .body)
                weatherCard(d.meta.id, b.input.highPoint)
                briefingCard(b)
                if aiRequest != nil && (model.writing || model.writeUp != nil) { writeUpCard }
                gemmaCard(b.prompt)
            } else {
                TMText("This route has no track, so there's nothing to brief.", .caption)
            }
        } else {
            TMText("Loading…", .caption)
        }
    }

    private func weatherCard(_ id: Int64, _ high: HighPoint?) -> some View {
        TMCard(spacing: 8) {
            TMText("Mountain weather", .title)
            TMText(weatherCaption(high), .caption)
            if let high, !model.fetching {
                TMButton(model.forecast == nil ? "Get forecast" : "Update forecast", icon: .download, style: .tonal) {
                    model.fetchForecast(id, high)
                }
            }
            TMLink(label: OpenMeteo.attribution, url: URL(string: OpenMeteo.url)!)
        }
    }

    private func weatherCaption(_ high: HighPoint?) -> String {
        guard let high else { return "This route has no heights, so there's no high point to forecast." }
        if model.fetching { return "Getting the forecast…" }
        guard let f = model.forecast else {
            return "Get the forecast for the high point (\(Units.elevation(high.eleM, imperial: prefs.imperial))) before you go. " +
                "It's saved on the phone, so the briefing below still has it without signal."
        }
        return "Saved \(Self.ago(f.fetchedMs)). The briefing below uses the hour you'd reach the high point."
    }

    private func briefingCard(_ b: BeaconBriefing) -> some View {
        TMCard(spacing: 8) {
            TMText("Offline briefing", .title)
            ForEach(Array(b.lines.enumerated()), id: \.offset) { _, line in
                TMText(BeaconText.bullet(line), .body, color: BeaconText.warns(line) ? p.danger : p.onSurface)
            }
            if !b.input.facilities.isEmpty { TMText(BeaconFeature.facilitiesAttribution, .caption) }
        }
    }

    private var writeUpCard: some View {
        TMCard(spacing: 10) {
            HStack(spacing: 8) {
                TMIconView(icon: .sparkle, size: 20, color: p.primary)
                TMText("Apple Intelligence write-up", .title)
            }
            .accessibilityElement(children: .combine)
            if let text = model.writeUp {
                Text(Self.rendered(text)).tm(.body, p).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                TMText("Written on this iPhone by Apple Intelligence from the offline briefing above; nothing left the phone. " +
                    "AI output can be wrong – never rely on it for safety decisions.", .caption)
                ActionRow {
                    TMButton("Copy", style: .tonal, fill: true) { AppModel.shared.copy("Write-up", text) }
                    TMButton("Share…", icon: .share, style: .tonal, fill: true) {
                        AppModel.shared.share([text], subject: "Hike briefing")
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().tint(p.primary)
                    TMText("Apple Intelligence is writing up the briefing on this iPhone…", .caption)
                }
            }
        }
    }

    private func gemmaCard(_ prompt: String) -> some View {
        TMCard(spacing: 10) {
            TMText("Ask Gemma on-device", .title)
            TMText("Google AI Edge Gallery runs Gemma models fully on the iPhone. Copy the prompt, open AI Chat with a Gemma model there, and paste. " +
                "You can also paste it into any assistant you trust.", .caption)
            TMButton("Copy Gemma prompt", icon: .sparkle) {
                AppModel.shared.copy("Beacon prompt", prompt)
                AppModel.shared.toast("Prompt copied. In Edge Gallery open AI Chat with a Gemma model and paste it.")
            }
            ActionRow {
                TMButton("Edge Gallery", style: .tonal, fill: true) { AppModel.shared.open(Self.edgeGalleryUrl) }
                    .accessibilityHint("Opens Google AI Edge Gallery in the App Store")
                TMButton("Share…", icon: .share, style: .tonal, fill: true) {
                    AppModel.shared.share([prompt], subject: "Hike briefing prompt")
                }
            }
            Text(prompt).tm(.caption, p).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Helpers

    /// "5 minutes ago", "yesterday"... as Android's relative time span.
    static func ago(_ ms: Int64) -> String {
        let seconds = Double(nowMs() - ms) / 1000
        if seconds >= 0 && seconds < 60 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        return f.localizedString(for: Date(timeIntervalSince1970: Double(ms) / 1000), relativeTo: Date())
    }

    /// The write-up with any bold or italic the model used, line breaks kept.
    static func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private func importGpx(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = url.pathExtension.lowercased() == "gpx" ? url.lastPathComponent : url.lastPathComponent + ".gpx"
        let copy = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: copy)
        do {
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            AppModel.shared.toast("Couldn't read \(url.lastPathComponent)")
            return
        }
        // GPX import (with heights added where needed) belongs to Routes, which handles opened GPX files.
        AppEvents.shared.open(copy)
    }
}

/// Picks the planned start: date and time together, as Android's date then time dialogs.
private struct BeaconStartPicker: View {
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    let onPick: (Int64) -> Void

    init(startMs: Int64, onPick: @escaping (Int64) -> Void) {
        _date = State(initialValue: Date(timeIntervalSince1970: Double(startMs) / 1000))
        self.onPick = onPick
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    TMText("Planned start", .title)
                    Spacer(minLength: 8)
                    TMButton("Done", style: .text) {
                        let minute = Calendar.current.dateInterval(of: .minute, for: date)?.start ?? date
                        onPick(Int64((minute.timeIntervalSince1970 * 1000).rounded()))
                        dismiss()
                    }
                }
                DatePicker("Planned start", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .tint(p.primary)
            }
            .padding(20)
        }
        .background(p.bg)
        .presentationDetents([.medium, .large])
    }
}
