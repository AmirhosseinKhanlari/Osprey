import OspreyLibrary
import SwiftUI

/// What the queue editor edits: a new queue (from the sidebar's +) or an existing one (Edit…).
struct QueueEditorRequest: Identifiable {
    let id = UUID()
    let queue: Queue
    let isNew: Bool

    /// A new queue, from the sidebar's + or Downloads › New Queue….
    static var newQueue: QueueEditorRequest { QueueEditorRequest(queue: Queue(name: "New queue"), isNew: true) }
}

extension Queue.AfterFinish {
    var title: String {
        switch self {
        case .nothing: "Do nothing"
        case .notify: "Notify me"
        case .quit: "Quit Osprey"
        case .sleep: "Sleep"
        case .shutdown: "Shut down"
        }
    }

    /// The line under the picker: what happens when the queue's downloads are done.
    var detail: String {
        switch self {
        case .nothing: "The queue stops when its downloads are done."
        case .notify: "A notification says when its downloads are done."
        case .quit: "Osprey quits when its downloads are done."
        case .sleep: "A 60-second countdown with Cancel comes first, then the Mac sleeps."
        case .shutdown: "A 60-second countdown with Cancel comes first, then the Mac shuts down."
        }
    }
}

/// Name, files at once, schedule (Manual / Once / Daily with weekdays), stop time, conditions and the after-finish
/// action, in two columns so every option is in view. Main shows only what applies to it: it always runs, keeps its
/// name and can't be scheduled.
///
/// Nothing changes size as options change: the schedule column keeps room for its tallest form (Daily), the stop time
/// stays in place (dimmed while off), and the after-finish line keeps room for its longest text.
struct QueueEditorSheet: View {
    private enum Kind: Hashable { case manual, once, daily }

    @Environment(DownloadManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    let request: QueueEditorRequest

    @State private var name: String
    @State private var maxConcurrent: Int
    @State private var kind: Kind
    @State private var onceStart: Date
    @State private var dailyTime: Date
    @State private var weekdays: Set<Int>
    @State private var hasStopTime: Bool
    @State private var stopTime: Date
    @State private var onlyOnWiFi: Bool
    @State private var onlyOnAC: Bool
    @State private var keepAwake: Bool
    @State private var afterFinish: Queue.AfterFinish
    /// Why Shut down can't run yet, shown in place of its line: never asked, or denied.
    @State private var shutdownNote: ShutdownNote?
    @State private var permissionCheck: Task<Void, Never>?
    /// The clock the "start in the future" check uses, moved on while the sheet is open so the hint appears (and Save
    /// turns off) once a Once start passes.
    @State private var now = Date()
    @FocusState private var nameFocused: Bool

    private static let calendar = Calendar.autoupdatingCurrent
    private static let rowHeight: CGFloat = 48
    private static let spacing: CGFloat = 16
    private static let hintHeight: CGFloat = 16
    private enum ShutdownNote: CaseIterable {
        case notAsked, denied

        var text: String {
            switch self {
            case .notAsked: "Choose Shut down again to let Osprey ask for permission."
            case .denied: "Osprey needs permission to control System Events to shut down. Allow it in System Settings → Privacy & Security → Automation."
            }
        }
    }

    init(request: QueueEditorRequest) {
        self.request = request
        let queue = request.queue
        let calendar = Self.calendar
        let now = Date()
        let today = calendar.startOfDay(for: now)
        func time(_ minutes: Int) -> Date { QueuePlanner.instant(minutes: minutes, on: today, calendar: calendar) ?? today }
        // A new "Once" start: the next whole hour.
        let nextHour = calendar.dateInterval(of: .hour, for: now)?.end ?? now.addingTimeInterval(3600)
        _name = State(initialValue: queue.name)
        _maxConcurrent = State(initialValue: queue.slots)
        switch queue.schedule {
        case .manual:
            _kind = State(initialValue: .manual)
            _onceStart = State(initialValue: nextHour)
            _dailyTime = State(initialValue: time(2 * 60))
            _weekdays = State(initialValue: Set(1...7))
        case .once(let start):
            _kind = State(initialValue: .once)
            _onceStart = State(initialValue: start)
            _dailyTime = State(initialValue: time(2 * 60))
            _weekdays = State(initialValue: Set(1...7))
        case .daily(let minutes, let days):
            _kind = State(initialValue: .daily)
            _onceStart = State(initialValue: nextHour)
            _dailyTime = State(initialValue: time(minutes))
            _weekdays = State(initialValue: days)
        }
        _hasStopTime = State(initialValue: queue.stopTime != nil)
        _stopTime = State(initialValue: time(queue.stopTime ?? 6 * 60))
        _onlyOnWiFi = State(initialValue: queue.onlyOnWiFi)
        _onlyOnAC = State(initialValue: queue.onlyOnAC)
        _keepAwake = State(initialValue: queue.keepAwake)
        _afterFinish = State(initialValue: queue.afterFinish)
    }

    private var isMain: Bool { request.queue.isMain }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why Save is off, shown under the schedule; nil when it can save.
    private var problem: String? {
        guard !isMain else { return nil }
        if trimmedName.isEmpty { return "Give the queue a name." }
        if manager.queues.contains(where: { $0.id != request.queue.id
            && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmedName) == .orderedSame }) {
            return "Another queue already has this name."
        }
        switch kind {
        case .daily where weekdays.isEmpty:
            return "Pick at least one day."
        case .once where onceStart <= now && request.queue.schedule != .once(start: onceStart):
            // A start that already passed would never run. One saved earlier may stay, so other edits still save.
            return "Pick a start in the future."
        default:
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.isNew ? "New queue" : "Edit “\(request.queue.name)”")
                    .font(.system(size: 19, weight: .bold)).tracking(-0.2)
                    .lineLimit(1)
                Text(isMain ? "Main runs at once: Start now and browser downloads go here."
                            : "Downloads you add to this queue wait for it to start.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            HStack(alignment: .top, spacing: Self.spacing) {
                leftColumn.frame(maxWidth: .infinity, alignment: .topLeading)
                rightColumn.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.capsule(.secondary, height: 36, fontSize: 13))
                    .keyboardShortcut(.cancelAction)
                Button(request.isNew ? "Add queue" : "Save") { save() }
                    .buttonStyle(.capsule(.primary, height: 36, fontSize: 13))
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(width: 760)
        .fixedSize(horizontal: false, vertical: true)
        .tint(Theme.accent)
        .onAppear {
            if request.isNew { nameFocused = true }
            if afterFinish == .shutdown { checkShutdownPermission(asking: false) }
        }
        .onDisappear { permissionCheck?.cancel() }
        // Only for Once: brings the clock up to date when the start changes, then wakes once when it passes. Other
        // schedules never redraw on a timer (a redraw closes open menus).
        .task(id: kind == .once ? onceStart : nil) {
            guard kind == .once else { return }
            now = Date()
            let wait = onceStart.timeIntervalSince(now)
            guard wait > 0 else { return }
            try? await Task.sleep(for: .seconds(wait + 0.5))
            if !Task.isCancelled { now = Date() }
        }
        // VoiceOver hears a hint as it appears; the hint's line is always laid out, so it can't announce itself.
        .onChange(of: problem) { _, hint in
            if let hint { AccessibilityNotification.Announcement(hint).post() }
        }
    }

    // MARK: Columns

    /// Name and files at once; then the schedule, with room kept for Daily's extra row and a line for what's missing.
    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            FormGroup {
                FormRow(title: "Name") { nameField }
                FormRow(title: "Files at once", showsDivider: false) {
                    ChipStepper(label: "files at once", values: Array(Queue.concurrencyRange), value: $maxConcurrent)
                }
            }
            if isMain {
                Text("Main can’t be renamed or scheduled: it starts as soon as it has downloads.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4)
                    .padding(.top, -8)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    scheduleGroup
                    Text(problem ?? " ")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.orange)
                        .lineLimit(1)
                        .frame(height: Self.hintHeight, alignment: .leading)
                        .padding(.leading, 4)
                        .accessibilityHidden(problem == nil)
                }
                // Room for Daily (Schedule, Starts at, On, Stop at): switching schedules never resizes the sheet.
                .frame(minHeight: Self.rowHeight * 4 + 6 + Self.hintHeight, alignment: .top)
            }
        }
    }

    /// Conditions and keep awake; then the after-finish action and what it does.
    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            FormGroup {
                if !isMain {
                    SettingsToggleRow(title: "Only on Wi-Fi", help: "Waits while on a phone hotspot or in Low Data Mode.",
                                      isOn: $onlyOnWiFi)
                    SettingsToggleRow(title: "Only when plugged in", help: "Waits while the Mac runs on battery.",
                                      isOn: $onlyOnAC)
                }
                SettingsToggleRow(title: "Keep the Mac awake",
                                  help: isMain ? "No sleep while its downloads run."
                                               : "No sleep while it runs. On power, no idle sleep in the 12 hours before it starts.",
                                  isOn: $keepAwake, showsDivider: false)
            }
            VStack(alignment: .leading, spacing: 8) {
                FormGroup {
                    FormRow(title: "After finishing", showsDivider: false) { afterFinishMenu }
                }
                afterFinishDetail.padding(.horizontal, 4)
            }
        }
    }

    // MARK: Controls

    @ViewBuilder private var nameField: some View {
        if isMain {
            Text(request.queue.name)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        } else {
            TextField("Name", text: $name, prompt: Text("Queue name"))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($nameFocused)
                .padding(.horizontal, 10)
                .frame(width: 190, height: 30)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(nameFocused ? Theme.accent.opacity(0.55) : .clear)
                }
                .onSubmit { if problem == nil { save() } }
        }
    }

    private var scheduleGroup: some View {
        FormGroup {
            FormRow(title: "Schedule") {
                ChipSegments(options: [(Kind.manual, "Manual"), (.once, "Once"), (.daily, "Daily")], selection: $kind)
            }
            switch kind {
            case .manual:
                FormRow(title: "Starts") {
                    Text("When you choose Start now")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                }
            case .once:
                FormRow(title: "Starts") {
                    DatePicker("Starts", selection: $onceStart, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .fixedSize()
                }
            case .daily:
                FormRow(title: "Starts at") {
                    DatePicker("Starts at", selection: $dailyTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .fixedSize()
                }
                FormRow(title: "On") { WeekdayToggles(selection: $weekdays, calendar: Self.calendar) }
            }
            FormRow(title: "Stop at", showsDivider: false) {
                HStack(spacing: 10) {
                    // Stays in place while off, dimmed, so the switch never moves.
                    DatePicker("Stop at", selection: $stopTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .fixedSize()
                        .disabled(!hasStopTime)
                    Toggle("Stop at a time", isOn: $hasStopTime)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(Theme.settingsSwitch)
                }
            }
        }
    }

    private var afterFinishMenu: some View {
        Menu {
            // Checkmarks on the current choice.
            Picker("After finishing", selection: Binding(get: { afterFinish }, set: { pick($0) })) {
                ForEach(Queue.AfterFinish.allCases, id: \.self) { action in
                    Text(action.title).tag(action)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            ChipLabel(text: afterFinish.title)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("After finishing, \(afterFinish.title)")
    }

    /// Every text is laid out and only the current one shows, so the group keeps the longest one's height.
    private var afterFinishDetail: some View {
        let note = afterFinish == .shutdown ? shutdownNote : nil
        return ZStack(alignment: .topLeading) {
            ForEach(Queue.AfterFinish.allCases, id: \.self) { action in
                detailText(action.detail, color: Theme.textSecondary, visible: note == nil && action == afterFinish)
            }
            ForEach(ShutdownNote.allCases, id: \.self) { candidate in
                detailText(candidate.text, color: Theme.orange, visible: note == candidate)
            }
        }
    }

    private func detailText(_ text: String, color: Color, visible: Bool) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(visible ? 1 : 0)
            .accessibilityHidden(!visible)
    }

    // MARK: Actions

    /// Picking Shut down asks macOS, if it hasn't asked before, to let Osprey control System Events; a refusal shows a
    /// note, and the choice stays.
    private func pick(_ action: Queue.AfterFinish) {
        afterFinish = action
        permissionCheck?.cancel()
        permissionCheck = nil
        shutdownNote = nil
        if action == .shutdown { checkShutdownPermission(asking: true) }
    }

    /// Picking Shut down asks (if macOS hasn't asked before); opening the editor on a queue already set to Shut down
    /// only checks, so it never brings up the prompt by itself.
    private func checkShutdownPermission(asking: Bool) {
        let finishActions = manager.system.finishActions
        permissionCheck = Task {
            let note: ShutdownNote?
            if asking {
                note = await finishActions.requestShutdownPermission() ? nil : .denied
            } else {
                switch await finishActions.shutdownPermission() {
                case .notAsked: note = .notAsked
                case .denied: note = .denied
                case .allowed, .unknown: note = nil
                }
            }
            guard !Task.isCancelled, afterFinish == .shutdown else { return }
            shutdownNote = note
        }
    }

    private func save() {
        guard problem == nil else { return }
        let calendar = Self.calendar
        var queue = request.queue
        if !isMain { queue.name = trimmedName }
        queue.maxConcurrent = maxConcurrent
        if !isMain {
            queue.schedule = switch kind {
            case .manual: .manual
            case .once: .once(start: calendar.dateInterval(of: .minute, for: onceStart)?.start ?? onceStart)
            case .daily: .daily(time: QueuePlanner.minutes(of: dailyTime, calendar: calendar), weekdays: weekdays)
            }
            queue.stopTime = hasStopTime ? QueuePlanner.minutes(of: stopTime, calendar: calendar) : nil
            queue.onlyOnWiFi = onlyOnWiFi
            queue.onlyOnAC = onlyOnAC
        }
        queue.keepAwake = keepAwake
        queue.afterFinish = afterFinish
        if request.isNew { manager.addQueue(queue) } else { manager.updateQueue(queue) }
        dismiss()
    }
}

/// S M T W T F S, in the calendar's week order; each a round toggle.
private struct WeekdayToggles: View {
    @Binding var selection: Set<Int>
    let calendar: Calendar

    var body: some View {
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        HStack(spacing: 4) {
            ForEach(order, id: \.self) { day in
                let on = selection.contains(day)
                Button {
                    if on { selection.remove(day) } else { selection.insert(day) }
                } label: {
                    Text(calendar.veryShortWeekdaySymbols[day - 1])
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(on ? Color.white : Theme.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(on ? Theme.accent : Theme.chip, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(calendar.weekdaySymbols[day - 1])
                .accessibilityLabel(calendar.weekdaySymbols[day - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}
