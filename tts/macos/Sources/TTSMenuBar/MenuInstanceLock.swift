import Darwin
import Foundation

final class MenuInstanceLock {
    private let store: QueueStore
    private var fileDescriptor: Int32 = -1

    init(store: QueueStore) {
        self.store = store
    }

    deinit {
        release()
    }

    func acquire(processID: Int32 = ProcessInfo.processInfo.processIdentifier) throws -> Bool {
        guard fileDescriptor == -1 else { return true }
        try store.prepare()

        let descriptor = open(store.lockFile.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw posixError("open")
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                return false
            }
            throw posixError("flock", code: lockError)
        }

        do {
            try Data("\(processID)\n".utf8).write(to: store.processFile, options: .atomic)
            fileDescriptor = descriptor
            return true
        } catch {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            throw error
        }
    }

    func release() {
        guard fileDescriptor >= 0 else { return }
        try? FileManager.default.removeItem(at: store.processFile)
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
        fileDescriptor = -1
    }

    private func posixError(_ operation: String, code: Int32 = errno) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "Unable to \(operation) TTS menu lock: \(String(cString: strerror(code)))"]
        )
    }
}
