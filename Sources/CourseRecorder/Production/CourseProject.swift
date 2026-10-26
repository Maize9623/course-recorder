import Foundation
import CoreGraphics

/// One timeline event of the production pass, at narration time `time`.
struct Cue: Codable, Equatable, Identifiable {
    enum Action: Codable, Equatable {
        case scene(SceneKind)
        case slide(Int)
        case demoSource(SourceRef)
        case slidesSource(SourceRef)
        case pip(Bool)
        case zoom(Bool)
        case lowerThird

        /// Cues of the same kind at the same moment replace each other.
        var kind: String {
            switch self {
            case .scene: "scene"
            case .slide: "slide"
            case .demoSource: "demoSource"
            case .slidesSource: "slidesSource"
            case .pip: "pip"
            case .zoom: "zoom"
            case .lowerThird: "lowerThird"
            }
        }
    }

    var id = UUID()
    var time: Double
    var action: Action
}

/// A screen capture recorded during the production pass; frame `p` of the file shows narration time `start + p`.
struct Take: Codable, Equatable, Identifiable {
    var id = UUID()
    var file: String
    var source: SourceRef
    var start: Double
    var end: Double
    var width: Int
    var height: Int
    var contentRect: CGRect
}

struct TimedPoint: Codable, Equatable {
    var t: Double
    var x: Double
    var y: Double
}

/// A narration-first course: the narration video plus everything recorded against its timeline.
struct CourseProject: Codable, Equatable {
    static let narrationFileName = "口播.mp4"
    static let outputFileName = "成片.mp4"
    static let takesFolder = "演示"
    static let fileName = "project.json"

    var version = 1
    var name: String
    var created = Date()
    /// Nil preserves the landscape canvas used by projects created before portrait support.
    var outputAspect: OutputAspect?
    var narrationFile: String?
    /// Imported media already contains its complete framing; do not apply live-camera full-frame zoom.
    var narrationIsImported: Bool?
    /// Relative metadata backup for restoring the last accepted narration edit.
    var narrationEditBackup: String?
    /// Captions on the current narration timeline, written beside project media.
    var subtitleFile: String?
    var narrationDuration: Double = 0
    var deckPath = ""
    var cues: [Cue] = []
    var takes: [Take] = []
    /// Cursor position on the demo source (normalized, top-left origin), sampled while operations were recorded.
    var cursor: [TimedPoint] = []
    var clicks: [TimedPoint] = []
    var includeBGM = true
    /// A project-local music copy. Nil uses the audio page's current playlist for legacy projects.
    var bgmFile: String?
    var outputFile: String?

    var hasNarration: Bool { narrationFile != nil && narrationDuration > 0 }

    var sortedCues: [Cue] { cues.sorted { $0.time < $1.time } }

    /// Adds a cue, replacing one of the same kind within 50 ms.
    mutating func add(_ action: Cue.Action, at time: Double) {
        cues.removeAll { abs($0.time - time) < 0.05 && $0.action.kind == action.kind }
        cues.append(Cue(time: time, action: action))
    }

    /// The take that shows narration time `t`: the most recently recorded one covering it.
    func take(at t: Double) -> Take? {
        takes.last { t >= $0.start && t < $0.end }
    }
}

enum ProjectStore {
    static func root(in recordings: URL) -> URL {
        recordings.appendingPathComponent("项目", isDirectory: true)
    }

    static func folder(named name: String, in recordings: URL) -> URL {
        root(in: recordings).appendingPathComponent(name, isDirectory: true)
    }

    /// Project folder names, most recently modified first.
    static func list(in recordings: URL) -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root(in: recordings), includingPropertiesForKeys: nil) else { return [] }
        return items
            .filter { fm.fileExists(atPath: $0.appendingPathComponent(CourseProject.fileName).path) }
            .sorted {
                let a = (try? $0.appendingPathComponent(CourseProject.fileName).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.appendingPathComponent(CourseProject.fileName).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .map(\.lastPathComponent)
    }

    static func load(_ folder: URL) -> CourseProject? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(CourseProject.fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CourseProject.self, from: data)
    }

    static func save(_ project: CourseProject, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(project).write(to: folder.appendingPathComponent(CourseProject.fileName), options: .atomic)
    }

    static func create(named rawName: String, deckPath: String, in recordings: URL,
                       outputAspect: OutputAspect = .landscape) throws -> (CourseProject, URL) {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if name.isEmpty {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH-mm"
            name = "课程 \(df.string(from: Date()))"
        }
        var folder = self.folder(named: name, in: recordings)
        var n = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = self.folder(named: "\(name) \(n)", in: recordings)
            n += 1
        }
        let project = CourseProject(name: folder.lastPathComponent, outputAspect: outputAspect, deckPath: deckPath)
        try save(project, to: folder)
        return (project, folder)
    }
}
