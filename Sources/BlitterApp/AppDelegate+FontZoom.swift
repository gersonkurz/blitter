import AppKit
import BlitterModel

/// The lists' font size (#63): the View menu's zoom items, and saving a zoomed size on quit.
extension AppDelegate {
    @objc func zoomIn(_: Any?) {
        workspace.perform(.zoomFont(.larger))
    }

    @objc func zoomOut(_: Any?) {
        workspace.perform(.zoomFont(.smaller))
    }

    @objc func actualSize(_: Any?) {
        workspace.perform(.zoomFont(.actualSize))
    }

    /// A zoomed font size still waiting to be saved (#63), or the Settings window's save (#64),
    /// is written first. The main thread stays
    /// free meanwhile; a save that hangs (a stalled network home) gives up after a few seconds.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard workspace.isSavingSettings else {
            return .terminateNow
        }
        Self.finishSaving(workspace) {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Waits for the workspace's pending saves, at most `limit`, then calls `done` once. The
    /// save and the limit race as two separate tasks: a save stuck on a stalled disk is left
    /// behind, not waited for.
    static func finishSaving(_ workspace: Workspace, limit: Duration = .seconds(3), done: @escaping () -> Void) {
        var isDone = false
        let finish = {
            if !isDone {
                isDone = true
                done()
            }
        }
        Task {
            await workspace.finishSaving()
            finish()
        }
        Task {
            try? await Task.sleep(for: limit)
            finish()
        }
    }
}
