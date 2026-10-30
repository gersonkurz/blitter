import Foundation

/// One `copyfile` call with byte progress and cancellation. `copyfile` reports success even when
/// the callback stopped it, so completeness is judged by the callback's own record.
final class DataCopy {
    let context: OperationContext
    private var currentFileBytes: Int64 = 0
    private var stopped = false
    private var error: String?

    init(context: OperationContext) {
        self.context = context
    }

    func copy(_ source: String, to target: String) -> (complete: Bool, error: String?) {
        guard let state = copyfile_state_alloc() else {
            return (false, "Could not start copying.")
        }
        defer { copyfile_state_free(state) }
        copyfile_state_set(
            state,
            UInt32(COPYFILE_STATE_STATUS_CB),
            unsafeBitCast(Self.callback, to: UnsafeRawPointer.self)
        )
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(self).toOpaque())
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW | COPYFILE_EXCL)
        let result = copyfile(source, target, state, flags)
        if result != 0, error == nil {
            error = FileOperations.message(errno)
        }
        return (result == 0 && !stopped && error == nil, error)
    }

    private static let callback: copyfile_callback_t = { what, stage, state, source, _, info in
        guard let info else {
            return COPYFILE_QUIT
        }
        let copy = Unmanaged<DataCopy>.fromOpaque(info).takeUnretainedValue()
        return copy.handle(what: what, stage: stage, state: state, source: source)
    }

    private func handle(what: Int32, stage: Int32, state: copyfile_state_t?,
                        source: UnsafePointer<CChar>?) -> Int32
    {
        if context.cancellation.isSet {
            stopped = true
            return COPYFILE_QUIT
        }
        switch (what, stage) {
        case (COPYFILE_RECURSE_FILE, COPYFILE_START):
            currentFileBytes = 0
        case (COPYFILE_COPY_DATA, COPYFILE_PROGRESS):
            var copied: off_t = 0
            copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
            let delta = Int64(copied) - currentFileBytes
            currentFileBytes = Int64(copied)
            context.update { $0.doneBytes += delta }
        case (_, COPYFILE_ERR):
            // Anything that cannot be copied ends the copy: a partial result is never kept.
            let path = source.map { String(cString: $0) } ?? ""
            error = "\(path): \(FileOperations.message(errno))"
            stopped = true
            return COPYFILE_QUIT
        default:
            break
        }
        return COPYFILE_CONTINUE
    }
}
