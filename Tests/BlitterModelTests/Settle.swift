@testable import BlitterModel
import Testing

extension Workspace {
    /// Waits until no read of any kind is pending. A finished read can start new ones (a listing
    /// reveals the folder in the tree, which reads its parents), so this repeats until idle.
    func settle() async {
        for _ in 0 ..< 20 {
            let pending = Array(rootsWork.values) + Array(pendingOpen.values) + Array(pendingWork.values)
                + treeWork.values.flatMap(\.values)
            guard !pending.isEmpty else {
                return
            }
            for task in pending {
                await task.value
            }
        }
        Issue.record("the workspace did not settle")
    }
}
