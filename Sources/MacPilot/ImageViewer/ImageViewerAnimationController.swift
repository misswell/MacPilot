import Foundation

@MainActor
final class ImageViewerAnimationController {
    private var timer: Task<Void, Never>?
    private(set) var completedLoops = 0
    var hasTimer: Bool { timer != nil }

    func next(after frame: Int, description: ImageViewerFrame) -> Int? {
        guard description.frameCount > 1 else { return nil }
        if frame + 1 < description.frameCount { return frame + 1 }
        if description.repeatCount > 0, completedLoops + 1 >= description.repeatCount { return nil }
        return 0
    }

    func displayed(_ frame: Int) {
        if frame == 0 { completedLoops += 1 }
    }

    func schedule(after delay: Double, advance: @escaping @MainActor () -> Void) {
        pause()
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.timer = nil
            advance()
        }
    }

    func pause() {
        timer?.cancel()
        timer = nil
    }

    func reset() {
        pause()
        completedLoops = 0
    }
}
