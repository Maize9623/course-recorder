import Foundation
import AppKit

extension AppState {
    func mergeFinishedRecording(_ result: RecordingResult, markers: [RecordingMarker],
                                completion: @escaping (RecordingResult) -> Void) {
        let worker = RecordingSegmentMerger()
        recordingMerger = worker
        recordingMergeProgress = 0
        recordingMergeStatus = "分段已保存，正在合并完整录像…"
        recordingMergeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.recordingMergeProgress = nil
                self.recordingMergeTask = nil
                self.recordingMerger = nil
            }
            do {
                let merged = try await worker.merge(files: result.files) { [weak self] value, message in
                    DispatchQueue.main.async {
                        guard self?.recordingMerger === worker else { return }
                        self?.recordingMergeProgress = value
                        self?.recordingMergeStatus = message
                    }
                }
                // Even if the caller cancels after publication, preserve the complete movie and every source.
                if Task.isCancelled {
                    self.recordingMergeStatus = "完整录像已保存；已取消清理，原分段仍保留"
                    self.showToast(self.recordingMergeStatus, icon: "checkmark.circle")
                    completion(RecordingResult(files: [merged.url]))
                    return
                }
                Recorder.writeMarkers(markers, for: merged.url)
                var canTrash = true
                if !markers.isEmpty {
                    for ext in ["markers.txt", "markers.srt"] {
                        let url = merged.url.deletingPathExtension().appendingPathExtension(ext)
                        if (try? Data(contentsOf: url).isEmpty) != false { canTrash = false }
                    }
                }
                try merged.validateSourcesUnchanged()
                var failures: [String] = []
                if canTrash {
                    for source in merged.sourceFiles {
                        do {
                            try FileManager.default.trashItem(at: source, resultingItemURL: nil)
                            for ext in ["markers.txt", "markers.srt"] {
                                let sidecar = source.deletingPathExtension().appendingPathExtension(ext)
                                if FileManager.default.fileExists(atPath: sidecar.path) {
                                    do { try FileManager.default.trashItem(at: sidecar, resultingItemURL: nil) }
                                    catch { failures.append(sidecar.lastPathComponent) }
                                }
                            }
                        } catch { failures.append(source.lastPathComponent) }
                    }
                }
                self.recordingMergeStatus = canTrash && failures.isEmpty
                    ? "完整录像已保存，原分段已移到废纸篓：\(merged.url.lastPathComponent)"
                    : "完整录像已保存；部分分段或标记未清理，请在录制目录查看"
                self.showToast(self.recordingMergeStatus, icon: failures.isEmpty && canTrash ? "checkmark.circle" : "exclamationmark.triangle")
                completion(RecordingResult(files: [merged.url]))
            } catch {
                self.recordingMergeStatus = error is CancellationError
                    ? "已取消合并，全部原分段仍保留"
                    : "合并未完成，全部原分段仍保留：\(error.localizedDescription)"
                self.showToast(self.recordingMergeStatus, icon: "exclamationmark.triangle")
                completion(result)
            }
        }
    }

    func cancelRecordingMerge() {
        suppressRecordingMerge = true
        guard recordingMergeProgress != nil else { return }
        recordingMergeStatus = "正在取消合并，原分段将保留…"
        recordingMergeTask?.cancel()
        recordingMerger?.cancel()
    }
}
