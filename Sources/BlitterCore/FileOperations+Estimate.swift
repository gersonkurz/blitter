import Foundation

/// A copy's total, measured beside it once it takes a while (#112), and whether a move stays on
/// one volume (then it is quick: a rename).
extension FileOperations {
    /// After `delay`, unless `stop` is set by then, measures the sources on a thread of its own
    /// at a lower priority than the job and reports their total, unless stopped meanwhile.
    static func estimate(_ sources: [String], after delay: Double, context: OperationContext, stop: CancellationFlag,
                         visit: (@Sendable (CancellationFlag) -> Void)?)
    {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            var total: Int64 = 0
            for source in sources {
                guard !stop.isSet else {
                    return
                }
                total += size(of: source, cancelled: stop, visit: visit)
            }
            if !stop.isSet {
                context.update { $0.totalBytes = total }
            }
        }
    }

    /// Whether every one of the items is on the volume `folder` is on (a move there is a rename,
    /// #112); false when that cannot be told.
    static func isOnVolume(of folder: String, _ items: [String]) -> Bool {
        var info = stat()
        guard stat(folder, &info) == 0 else {
            return false
        }
        let device = info.st_dev
        return items.allSatisfy { item in
            var itemInfo = stat()
            return lstat(item, &itemInfo) == 0 && itemInfo.st_dev == device
        }
    }
}
