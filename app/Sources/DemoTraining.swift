import SwiftUI
import AppKit
import Darwin

// MARK: – Model

@MainActor @Observable
final class DemoTrainingModel {
    enum TrainState { case idle, running, done }

    var folder: URL?
    var timescale: Int = 16
    var state: TrainState = .idle
    var log: [String] = []
    var currentDemo = ""
    var demoIndex = 0
    var demoTotal = 0
    var recipesAtStart = 0
    var recipesNow = 0

    private var trainTask: Task<Void, Never>?
    private var stopRequested = false

    func start(root: URL, helper: URL) {
        guard let folder, state == .idle else { return }
        stopRequested = false
        state = .running
        log = []

        let cfgDir = root
            .appendingPathComponent("environment/drive_c/Program Files (x86)/Steam/steamapps/common/Counter-Strike Global Offensive/game/csgo/cfg")
        let demoCfg = cfgDir.appendingPathComponent("macvolvo_demo.cfg")
        // Ensure autoexec.cfg execs macvolvo_demo.cfg (CS2 silently ignores exec for missing files)
        let autoexec = cfgDir.appendingPathComponent("autoexec.cfg")
        if let existing = try? String(contentsOf: autoexec, encoding: .utf8), !existing.contains("exec macvolvo_demo") {
            try? (existing + "\nexec macvolvo_demo\n").write(to: autoexec, atomically: true, encoding: .utf8)
        }

        let demos = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "dem" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        guard !demos.isEmpty else {
            appendLog("No .dem files found in the selected folder.")
            state = .done
            return
        }
        demoTotal = demos.count
        demoIndex = 0
        recipesAtStart = countRecipes(root: root)
        recipesNow = recipesAtStart
        appendLog("Start: \(demos.count) demos, \(recipesAtStart) recipes")
        let ts = timescale

        trainTask = Task {
            defer {
                try? "".write(to: demoCfg, atomically: true, encoding: .utf8)
                state = .done
                appendLog("Done. New recipes: \(recipesNow - recipesAtStart)")
            }
            for (i, demo) in demos.enumerated() {
                if stopRequested { appendLog("Stopped."); return }
                demoIndex = i + 1
                currentDemo = demo.lastPathComponent
                appendLog("[\(i+1)/\(demos.count)] \(currentDemo)")

                if await cs2Running() {
                    appendLog("  Closing previous CS2...")
                    await closeCS2(helper: helper, root: root)
                }

                let winPath = "Z:" + demo.path.replacingOccurrences(of: "/", with: "\\")
                let cfg = "bind \"F9\" \"demo_timescale \(ts)\"\nplaydemo \"\(winPath)\"\n"
                try? cfg.write(to: demoCfg, atomically: true, encoding: .utf8)

                let before = countRecipes(root: root)
                appendLog("  Launching CS2...")
                Task.detached { [helper, root] in
                    runProcess(helper.path, ["launch", "--game", "cs2", "--root", root.path])
                }

                var started = false
                for _ in 0..<60 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if await cs2Running() { appendLog("  CS2 ready"); started = true; break }
                }
                if !started { appendLog("  CS2 did not start, skipping"); continue }

                try? await Task.sleep(nanoseconds: 25_000_000_000)
                if !stopRequested { await sendF9andMinimize() }

                var idle = 0
                var prev = before
                while await cs2Running() && !stopRequested {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    let now = countRecipes(root: root)
                    recipesNow = now
                    let new = now - prev
                    if new > 0 { appendLog("  \(now) recipes (+\(new))"); prev = now; idle = 0 }
                    else { idle += 5; if idle >= 60 { break } }
                }

                appendLog("  Closing CS2...")
                await closeCS2(helper: helper, root: root)
                appendLog("  New recipes: \(countRecipes(root: root) - before)")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stop() { stopRequested = true; trainTask?.cancel() }

    private func appendLog(_ line: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.append("[\(ts)] \(line)")
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    private func closeCS2(helper: URL, root: URL) async {
        await Task.detached {
            runProcess(helper.path, ["close-client", "--root", root.path])
            runProcess("/usr/bin/pkill", ["-f", "cs2.exe"])
        }.value
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !(await cs2Running()) { break }
        }
    }
}

func countRecipes(root: URL) -> Int {
#if MACVOLVO_GPTK4
    // GPTK4 uses D3DMetal; shader cache lives in macOS GPU Archiver under the game-mode bundle ID.
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 else { return 0 }
    let archiver = URL(fileURLWithPath: String(cString: buffer))
        .appendingPathComponent("app.macvolvo.gptk4.game.cs2")
        .appendingPathComponent("com.apple.gpuarchiver")
    guard let en = FileManager.default.enumerator(at: archiver, includingPropertiesForKeys: nil) else { return 0 }
    var count = 0
    for case let url as URL in en where url.pathExtension == "metallib" { count += 1 }
    return count
#else
    let cache = root.appendingPathComponent("cache/pipelines")
    guard let en = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: nil) else { return 0 }
    var count = 0
    for case let url as URL in en where url.pathExtension == "json" && url.pathComponents.contains("recipes") { count += 1 }
    return count
#endif
}

func cs2Running() async -> Bool {
    await Task.detached {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-if", "cs2.exe"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus == 0
    }.value
}

func sendF9andMinimize() async {
    await Task.detached {
        let script = """
        tell application "System Events"
            repeat with p in (every process)
                try
                    if (name of p) contains "wine" then
                        set frontmost of p to true
                        delay 1
                        key code 101
                        delay 0.5
                        set miniaturized of (first window of p) to true
                    end if
                end try
            end repeat
        end tell
        """
        runProcess("/usr/bin/osascript", ["-e", script])
    }.value
}

func runProcess(_ path: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
}

// MARK: – Sheet View

struct DemoTrainingSheet: View {
    @Bindable var model: AppModel
    @State private var training = DemoTrainingModel()
    @State private var showFolderPicker = false

    var body: some View {
        VStack(spacing: 0) {
            trainingSheetHeader
            ScrollView {
                VStack(spacing: 16) {
                    configPanel
                    if training.state == .running && training.demoTotal > 0 { progressPanel }
                    actionButton
                    if !training.log.isEmpty { logPanel }
                    Text("Each demo plays at the selected speed. CS2 opens and closes automatically.")
                        .font(LauncherStyle.font(12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(24)
            }
        }
        .frame(width: LauncherStyle.contentWidth)
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { training.folder = url }
        }
    }

    private var trainingSheetHeader: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Build Shader Cache", systemImage: "film.stack")
                    .font(LauncherStyle.font(15, .semibold))
                Spacer()
                Button { model.sheet = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20)).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
                }.buttonStyle(.borderless).keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
        }
    }

    private var configPanel: some View {
        LauncherPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Demo folder").font(LauncherStyle.font(13)).foregroundStyle(.secondary)
                    Spacer()
                    Button(training.folder?.lastPathComponent ?? "Choose…") { showFolderPicker = true }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                        .disabled(training.state == .running)
                }
                HStack {
                    Text("Playback speed").font(LauncherStyle.font(13)).foregroundStyle(.secondary)
                    Spacer()
                    Picker("Timescale", selection: $training.timescale) {
                        Text("4×").tag(4); Text("8×").tag(8); Text("16×").tag(16); Text("32×").tag(32)
                    }.labelsHidden().pickerStyle(.menu).fixedSize().disabled(training.state == .running)
                }
                Divider()
                HStack {
                    Text("Shader recipes").font(LauncherStyle.font(13)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(training.state == .idle ? model.recipeCount : training.recipesNow)")
                        .font(LauncherStyle.font(13, .semibold)).monospacedDigit()
                    if training.state == .running && training.recipesNow > training.recipesAtStart {
                        Text("(+\(training.recipesNow - training.recipesAtStart))")
                            .font(LauncherStyle.font(13)).foregroundStyle(LauncherStyle.accent)
                    }
                }
            }
        }
    }

    private var progressPanel: some View {
        LauncherPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ProgressView(value: Double(training.demoIndex), total: Double(training.demoTotal))
                        .tint(LauncherStyle.accent)
                    Text("\(training.demoIndex) / \(training.demoTotal)")
                        .font(LauncherStyle.font(12)).monospacedDigit().foregroundStyle(.secondary)
                }
                if !training.currentDemo.isEmpty {
                    Text(training.currentDemo)
                        .font(LauncherStyle.font(12)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    private var actionButton: some View {
        Group {
            if training.state == .running {
                Button("Stop") { training.stop() }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
            } else {
                LauncherPrimaryAction(
                    title: training.state == .done ? "Run Again" : "Run",
                    action: {
                        if training.state == .done { training.state = .idle }
                        training.start(root: model.root, helper: model.service.helper)
                    }
                ).disabled(training.folder == nil)
            }
        }
    }

    private var logPanel: some View {
        LauncherPanel {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(training.log.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }.padding(4)
                }
                .frame(maxHeight: 180)
                .onChange(of: training.log.count) { _, _ in
                    if let last = training.log.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }
}
