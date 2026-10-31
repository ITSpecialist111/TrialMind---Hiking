import AudioToolbox
import AVFoundation
import MessageUI
import UIKit
import UserNotifications

/// The fall alarm (frontier/FallAlert.kt): after a possible fall, an alarm and a 60-second "Are you OK?" countdown, then
/// the SOS text to the emergency contact with your grid reference, a map link and your battery. iOS lets no app send a
/// text by itself, so where Android may send it, iPhone opens it in Messages for a tap on Send (straight away, if the user
/// chose that). The alarm's state lives in Prefs under Android's keys, so it survives TrailMind being closed.
final class FallAlarm: ObservableObject {
    static let shared = FallAlarm()

    @Published private(set) var state: FallAlarmState
    /// The clock the countdown shows, moved on once a second while it runs.
    @Published private(set) var now: Int64 = nowMs()

    private var timer: Timer?
    private var ticks = 0
    private let sound = AlarmSound()
    private var started = false
    /// The alert whose alarm screen the user put away, so coming back to TrailMind doesn't push it in front again.
    private var putAwayMs: Int64 = 0
    /// The alert whose SOS text TrailMind already opened by itself ("Open the SOS text straight away").
    private var openedMs: Int64 = 0

    init() {
        let p = Prefs.shared
        var s = FallAlarmState()
        s.stage = FallAlarmStage(rawValue: p.fallStage) ?? .none
        // Only Android sends the text itself; an Android "sending" stage means the text is ready here.
        if s.stage == .sending { s.stage = .textReady }
        s.alertMs = p.fallAlertMs
        s.situation = p.sosSituation
        s.failed = p.sosFailed
        s.sentMs = p.sosSentMs
        s.recipient = p.sosRecipient
        state = s
    }

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.cameToFront()
        }
        // Leaving TrailMind mid-countdown puts the alarm on the lock screen, where "I'm OK" asks for Face ID or the passcode.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.state.stage == .countdown else { return }
            self.postCountdown()
        }
        refresh()
        if state.stage == .countdown {
            startTicking()
            if Prefs.shared.fallAlarmSound { sound.start() }
        }
        if UIApplication.shared.applicationState == .active { cameToFront() }
    }

    // MARK: Who and what

    /// The number the SOS text goes to: once it has gone, the number it went to, even if the contact changed since.
    var recipientNumber: String {
        KotlinText.isBlank(state.recipient) ? Prefs.shared.emergencyContact : state.recipient
    }

    var contactName: String {
        let prefs = Prefs.shared
        return FallAlarmText.contactName(number: recipientNumber, contactNumber: prefs.emergencyContact,
                                         contactName: prefs.emergencyContactName)
    }

    /// "I'm OK" also offers the all-clear to whoever the SOS text went to.
    var tellsContact: Bool {
        state.stage == .sent && !KotlinText.isBlank(state.recipient) && !SosText.isEmergencyNumber(state.recipient)
    }

    /// TrailMind may open the SOS text by itself: the user chose that, set a contact that isn't 999, and the phone can text.
    var opensTextItself: Bool {
        let prefs = Prefs.shared
        return prefs.sosAutoSend && !KotlinText.isBlank(prefs.emergencyContact) && !SosText.isEmergencyNumber(prefs.emergencyContact) &&
            SafetyMessages.canText
    }

    /// The SOS text as it would go now (FallAlert.message): one plain SMS of at most 160 characters.
    func message(_ situation: String? = nil, at: Int64 = nowMs()) -> String {
        let here = SafetyLocation.whereNow(at)
        let what = situation ?? (KotlinText.isBlank(state.situation) ? FallAlarmState.noResponse : state.situation)
        return SosText.contact(what, location: here?.latLon, altitudeM: here?.altitudeM, time: SafetyFormat.clockForText(at),
                               batteryPercent: SafetyFormat.batteryPercent(), words: currentWords(here?.latLon))
    }

    /// For 999 by emergencySMS; never opened by itself, the user reads it and sends it.
    func emergencyMessage() -> String {
        let here = SafetyLocation.whereNow()?.latLon
        return SosText.emergency(KotlinText.isBlank(state.situation) ? FallAlarmState.help : state.situation, location: here,
                                 time: SafetyFormat.clockForText(nowMs()), words: currentWords(here))
    }

    /// The what3words address, only while it still names this square from the last minute.
    private func currentWords(_ here: LatLon?) -> String? {
        guard let here, let address = What3wordsLookup.shared.current(LocationHub.shared.latest), address.contains(here) else { return nil }
        return address.words
    }

    // MARK: The alarm

    /// After a detected fall: the alarm and countdown, unless one is already running (FallAlert.start).
    func trigger() {
        var s = state
        guard s.start(nowMs()) else { return }
        putAwayMs = 0
        update(s)
        let name = contactName
        // The no-answer alert is scheduled now, so it comes at the deadline even if iOS stops TrailMind meanwhile.
        var ended = s
        _ = ended.countdownEnded()
        let ready = FallAlarmText.readyNotification(ended, name)
        SafetyNotifications.shared.post(.fallReady, title: ready.title, body: ready.body, category: SafetyNotifications.Category.fallReady,
                                        at: Date(timeIntervalSince1970: Double(s.deadlineMs) / 1000),
                                        userInfo: ["alertMs": NSNumber(value: s.alertMs)])
        if Prefs.shared.fallAlarmSound { sound.start() }
        startTicking()
        if UIApplication.shared.applicationState == .active {
            FallAlarmWindow.shared.show()
        } else {
            postCountdown()
        }
    }

    /// "Are you OK?" with I'm OK and Send SOS now, for the lock screen. With the alarm already sounding, it only needs to
    /// be seen; otherwise it sounds the alarm tone (notification sounds follow the ring/silent switch).
    private func postCountdown() {
        let n = FallAlarmText.countdownNotification(contactName)
        let tone: UNNotificationSound? = sound.isPlaying ? nil : (Prefs.shared.fallAlarmSound ? AlarmSound.notificationSound() : .default)
        SafetyNotifications.shared.post(.fallCountdown, title: n.title, body: n.body, category: SafetyNotifications.Category.fallCountdown,
                                        userInfo: ["alertMs": NSNumber(value: state.alertMs)], sound: tone)
    }

    /// Catches up with the clock: a countdown that ran out while TrailMind wasn't running gets the text ready.
    func refresh() {
        if state.stage == .countdown && nowMs() >= state.deadlineMs { countdownEnded() }
        now = nowMs()
    }

    /// The user asks for help: the SOS text is made ready and Messages opens with it (FallAlertActivity.sendNow).
    func sendNow(_ situation: String = FallAlarmState.fallHelp) {
        var s = state
        s.sendNow(nowMs(), situation: situation)
        update(s)
        silence()
        SafetyNotifications.shared.cancel([.fallCountdown, .fallReady])
        FallAlarmWindow.shared.show()
        openText()
    }

    /// "I'm OK": the alarm stops and the emergency clears. If the SOS text went, Messages opens with the all-clear for the
    /// person who got it (Android sends that itself when it sent the SOS itself).
    func ok() {
        let tell = tellsContact
        let recipient = state.recipient
        let sentMs = state.sentMs
        var s = state
        s.ok()
        update(s)
        silence()
        SafetyNotifications.shared.cancel([.fallCountdown, .fallReady])
        FrontierStatus.shared.clearEmergency()
        FallAlarmWindow.shared.hide()
        if tell {
            SafetyUI.afterDialog {
                SafetyMessages.shared.compose(recipient, FallAlarmText.allClear(sentTime: SafetyFormat.clockForText(sentMs)))
            }
        }
    }

    /// Opens Messages with the SOS text for the contact; what Messages reports moves the alarm on.
    func openText() {
        let number = recipientNumber
        let at = nowMs()
        openedMs = state.alertMs
        SafetyMessages.shared.compose(number, message(at: at)) { [weak self] result in
            self?.composed(result, number: number, textMs: at)
        }
    }

    private func composed(_ result: MessageComposeResult, number: String, textMs: Int64) {
        var s = state
        switch result {
        case .sent: s.textSent(to: number, textMs: textMs)
        case .failed: s.textFailed()
        default: return
        }
        update(s)
    }

    /// The alarm screen, in front again (Safety → "Open the fall alarm").
    func showScreen() {
        guard state.stage != .none else { return }
        putAwayMs = 0
        FallAlarmWindow.shared.show()
    }

    /// The alarm screen goes away; the alarm itself carries on (only "I'm OK" stops it).
    func putAway() {
        putAwayMs = state.alertMs
        FallAlarmWindow.shared.hide()
    }

    // MARK: From notifications (actions from an alert that has ended or been replaced are ignored)

    func ok(alertMs: Int64) {
        guard alertMs == state.alertMs, state.stage != .none else { return }
        ok()
    }

    func sendNowFromNotification(alertMs: Int64) {
        guard alertMs == state.alertMs, state.running else { return }
        SafetyUI.whenReady { self.sendNow() }
    }

    func textFromNotification(alertMs: Int64) {
        guard alertMs == state.alertMs, state.running else { return }
        SafetyUI.whenReady {
            self.showScreen()
            self.openText()
        }
    }

    /// A tap on an alarm notification: the alarm screen, once TrailMind is in front.
    func showWhenReady() {
        SafetyUI.whenReady { self.showScreen() }
    }

    private func cameToFront() {
        refresh()
        guard state.running, putAwayMs != state.alertMs else { return }
        FallAlarmWindow.shared.show()
        if state.stage == .textReady && opensTextItself && openedMs != state.alertMs {
            SafetyUI.afterDialog { if self.state.stage == .textReady { self.openText() } }
        }
    }

    // MARK: Countdown

    private func countdownEnded() {
        var s = state
        guard s.countdownEnded() else { return }
        update(s)
        silence()
        // The no-answer notification scheduled at the start comes now.
        SafetyNotifications.shared.cancel([.fallCountdown])
        if UIApplication.shared.applicationState == .active {
            if putAwayMs != s.alertMs { FallAlarmWindow.shared.show() }
            if opensTextItself && openedMs != s.alertMs { openText() }
        }
    }

    private func startTicking() {
        timer?.invalidate()
        ticks = 0
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        now = nowMs()
        guard state.stage == .countdown else {
            silence()
            return
        }
        if now >= state.deadlineMs {
            countdownEnded()
            return
        }
        ticks += 1
        buzz()
    }

    /// Strong vibration every second while the countdown runs (Android's 800 ms pulses).
    private func buzz() {
        if UIApplication.shared.applicationState == .active {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: 1)
            }
        } else if ticks % 2 == 0 {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }

    private func silence() {
        timer?.invalidate()
        timer = nil
        sound.stop()
    }

    private func update(_ s: FallAlarmState) {
        state = s
        now = nowMs()
        let p = Prefs.shared
        p.fallStage = s.stage.rawValue
        p.fallAlertMs = s.alertMs
        p.sosSituation = s.situation
        p.sosFailed = s.failed
        p.sosSentMs = s.sentMs
        p.sosRecipient = s.recipient
        p.sosAttempts = 0
    }
}

/// The alarm's sound: the generated tone looping on the speaker until stopped. The audio session plays it even with
/// the ring/silent switch on silent, and lowers other audio while it sounds.
final class AlarmSound {
    private var player: AVAudioPlayer?
    private static let tone = Data(AlarmTone.wav())
    private static let soundName = "trailmind-fall-alarm.wav"

    var isPlaying: Bool { player?.isPlaying == true }

    /// Starts the loop; false if iOS refused (for example in the background, where a notification sounds instead).
    @discardableResult
    func start() -> Bool {
        if player?.isPlaying == true { return true }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
            let p = try AVAudioPlayer(data: Self.tone, fileTypeHint: AVFileType.wav.rawValue)
            p.numberOfLoops = -1
            p.volume = 1
            p.prepareToPlay()
            guard p.play() else { return false }
            player = p
            return true
        } catch {
            return false
        }
    }

    func stop() {
        guard let p = player else { return }
        p.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The same alarm as a notification sound (up to 30 seconds are allowed), written once to Library/Sounds where iOS
    /// looks for an app's own notification sounds. Notification sounds follow the ring/silent switch.
    static func notificationSound() -> UNNotificationSound {
        let fm = FileManager.default
        guard let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else { return .default }
        let dir = library.appendingPathComponent("Sounds", isDirectory: true)
        let file = dir.appendingPathComponent(soundName)
        if !fm.fileExists(atPath: file.path) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data(AlarmTone.wav(seconds: 29)).write(to: file, options: .atomic)
            } catch {
                return .default
            }
        }
        return UNNotificationSound(named: UNNotificationSoundName(soundName))
    }
}
