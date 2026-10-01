import Foundation
import Combine
import UserNotifications
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "leise-mac", category: "RecordingReminderService")

/// Decides when to remind the user that the recorder is still running: after
/// a minute of silence, then every 30 minutes while the recording goes on.
struct RecordingReminderPolicy {
    enum Reason: Equatable {
        case silence
        case periodic
    }

    /// Recorder levels are `min(1, rms * 5)`, so this is roughly -40 dBFS.
    static let silenceLevelThreshold: Float = 0.05
    static let silenceDuration: TimeInterval = 60
    static let repeatInterval: TimeInterval = 30 * 60
    /// Keeps short noises (a cough, a door) that re-arm the silence reminder
    /// from turning it into a stream of notifications.
    static let minimumSilenceReminderSpacing: TimeInterval = 10 * 60

    private let startedAt: Date
    private(set) var lastSoundAt: Date
    private(set) var lastReminderAt: Date?

    init(startedAt: Date) {
        self.startedAt = startedAt
        lastSoundAt = startedAt
    }

    mutating func recordLevel(_ level: Float, at date: Date) {
        if level >= Self.silenceLevelThreshold {
            lastSoundAt = date
        }
    }

    /// Returns why a reminder is due at `now`, and counts it as sent.
    mutating func reminderDue(at now: Date) -> Reason? {
        let reason: Reason?
        if isSilenceReminderDue(at: now) {
            reason = .silence
        } else if now.timeIntervalSince(lastReminderAt ?? startedAt) >= Self.repeatInterval {
            reason = .periodic
        } else {
            reason = nil
        }

        if reason != nil {
            lastReminderAt = now
        }
        return reason
    }

    private func isSilenceReminderDue(at now: Date) -> Bool {
        guard now.timeIntervalSince(lastSoundAt) >= Self.silenceDuration else { return false }
        guard let lastReminderAt else { return true }
        // One silence reminder per silent stretch; the periodic reminder
        // covers a stretch that simply continues.
        return lastSoundAt > lastReminderAt
            && now.timeIntervalSince(lastReminderAt) >= Self.minimumSilenceReminderSpacing
    }
}

/// Posts "still recording" notifications with a Stop action, so a recorder
/// session the user forgot about does not run for hours.
@MainActor
final class RecordingReminderService: NSObject {
    private nonisolated static let categoryIdentifier = "recorder.stillRecording"
    private nonisolated static let stopActionIdentifier = "recorder.stillRecording.stop"
    private nonisolated static let notificationIdentifier = "recorder.stillRecording"
    private static let checkInterval: TimeInterval = 5

    private let recorder: AudioRecorderViewModel
    private var policy: RecordingReminderPolicy?
    private var checkTimer: Timer?
    private var hasRequestedAuthorization = false
    private var cancellables = Set<AnyCancellable>()

    init(recorder: AudioRecorderViewModel) {
        self.recorder = recorder
        super.init()
    }

    func startObserving() {
        let center = UNUserNotificationCenter.current()
        let stopAction = UNNotificationAction(
            identifier: Self.stopActionIdentifier,
            title: String(localized: "recorder.stopRecording")
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryIdentifier,
                actions: [stopAction],
                intentIdentifiers: []
            )
        ])
        center.delegate = self

        recorder.$state
            .removeDuplicates()
            .sink { [weak self] state in
                self?.recorderStateDidChange(state)
            }
            .store(in: &cancellables)

        recorder.$micLevel
            .merge(with: recorder.$systemLevel)
            .sink { [weak self] level in
                self?.policy?.recordLevel(level, at: Date())
            }
            .store(in: &cancellables)
    }

    private func recorderStateDidChange(_ state: AudioRecorderViewModel.RecorderState) {
        guard state == .recording else {
            stopTracking()
            return
        }
        guard policy == nil else { return }

        policy = RecordingReminderPolicy(startedAt: Date())
        requestAuthorizationIfNeeded()
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.postReminderIfDue()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
    }

    private func stopTracking() {
        guard policy != nil else { return }
        policy = nil
        checkTimer?.invalidate()
        checkTimer = nil
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [Self.notificationIdentifier])
    }

    /// Asked on the first recording rather than at launch, so users who never
    /// record never see the permission prompt.
    private func requestAuthorizationIfNeeded() {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        Task {
            do {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            } catch {
                logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func postReminderIfDue() {
        guard let reason = policy?.reminderDue(at: Date()) else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Leise is still recording")
        switch reason {
        case .silence:
            content.body = String(localized: "No sound for a minute. Do you want to stop the recording?")
        case .periodic:
            let elapsed = Duration.seconds(Int(recorder.duration))
                .formatted(.units(allowed: [.hours, .minutes], width: .wide))
            content.body = String(localized: "Recording for \(elapsed). Do you want to stop it?")
        }
        content.categoryIdentifier = Self.categoryIdentifier
        content.sound = .default

        // A fixed identifier replaces the previous reminder instead of stacking them.
        let request = UNNotificationRequest(identifier: Self.notificationIdentifier, content: content, trigger: nil)
        Task { [weak self] in
            let center = UNUserNotificationCenter.current()
            do {
                try await center.add(request)
            } catch {
                logger.error("Recording reminder failed: \(error.localizedDescription, privacy: .public)")
            }
            // The recording may have stopped while the request was in flight;
            // stopTracking() ran its removal before this one was delivered.
            if self?.policy == nil {
                center.removeDeliveredNotifications(withIdentifiers: [Self.notificationIdentifier])
            }
        }
    }
}

extension RecordingReminderService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == Self.stopActionIdentifier else { return }
        await MainActor.run {
            recorder.stopRecording()
        }
    }
}
