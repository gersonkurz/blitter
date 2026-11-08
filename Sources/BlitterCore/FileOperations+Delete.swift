import Foundation

extension FileOperations {
    mutating func trash(_ paths: [String]) {
        context.update { $0.totalItems = paths.count }
        for path in paths {
            guard !isCancelled else {
                return
            }
            context.update { $0.currentItem = (path as NSString).lastPathComponent }
            do {
                if let trashed = try trashItem(path) {
                    recordMove(trashed, back: path)
                }
            } catch {
                fail(path, error.localizedDescription)
            }
            context.update { $0.doneItems += 1 }
        }
    }

    mutating func delete(_ paths: [String]) {
        context.update { $0.totalItems = paths.count }
        for path in paths {
            guard !isCancelled else {
                return
            }
            context.update { $0.currentItem = (path as NSString).lastPathComponent }
            let cancellation = context.cancellation
            let code = Self.deleteForGood(path) { cancellation.isSet }
            if code == ECANCELED {
                if Self.exists(path) {
                    fail(path, "Deleting was cancelled; some of its contents may already be gone.")
                }
            } else if code != 0 {
                fail(path, Self.message(code))
            }
            context.update { $0.doneItems += 1 }
        }
    }

    /// Deletes an item for good; a folder with everything in it. Symbolic links are removed, never
    /// followed. `stop` is asked before each item inside, so cancelling a large folder takes
    /// effect at once. Returns 0, ECANCELED when stopped, or the errno of the first failure.
    static func deleteForGood(_ path: String, stop: () -> Bool) -> Int32 {
        guard let state = removefile_state_alloc() else {
            return ENOMEM
        }
        defer { removefile_state_free(state) }
        // removefile reports success even when the callback stopped it, so remember that here.
        var stopped = false
        let code = withoutActuallyEscaping(stop) { stop in
            var context: () -> Bool = {
                stopped = stopped || stop()
                return stopped
            }
            return withUnsafeMutablePointer(to: &context) { pointer in
                let confirm: @convention(c) (removefile_state_t?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?)
                    -> Int32 = { _, _, context in
                        let stop = context?.assumingMemoryBound(to: (() -> Bool).self).pointee
                        return stop?() == true ? Int32(REMOVEFILE_STOP) : Int32(REMOVEFILE_PROCEED)
                    }
                removefile_state_set(state, UInt32(REMOVEFILE_STATE_CONFIRM_CALLBACK),
                                     unsafeBitCast(confirm, to: UnsafeRawPointer.self))
                removefile_state_set(state, UInt32(REMOVEFILE_STATE_CONFIRM_CONTEXT), pointer)
                return removefile(path, state, removefile_flags_t(REMOVEFILE_RECURSIVE)) == 0 ? 0 : errno
            }
        }
        return stopped ? ECANCELED : code
    }
}
