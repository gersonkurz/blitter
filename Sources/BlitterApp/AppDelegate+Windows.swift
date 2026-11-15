import AppKit
import BlitterModel

/// The main windows (#96): New Window, and their Git windows.
extension AppDelegate {
    /// File → New Window (⌘N, #96): another window, both its sides at the active side's folder.
    @objc func newWindow(_: Any?) {
        workspace.perform(.runAction("new-window", workspace.activeSide))
    }

    /// Each Git window is made for the main window that asked for it (#96).
    func registerDialogs() {
        DialogHost.register(DialogRequest.gitLog) { request, workspace in
            GitLogWindowController(workspace: workspace, path: request.path)
        }
        DialogHost.register(DialogRequest.gitSync) { request, workspace in
            GitSyncWindowController(workspace: workspace, path: request.path)
        }
        DialogHost.register(DialogRequest.gitCommit) { request, workspace in
            GitCommitWindowController(workspace: workspace, path: request.path)
        }
        DialogHost.register(DialogRequest.gitClone) { request, workspace in
            GitCloneWindowController(workspace: workspace, folder: request.path)
        }
        DialogHost.register(DialogRequest.gitClean) { request, workspace in
            GitCleanWindowController(workspace: workspace, path: request.path)
        }
    }
}
