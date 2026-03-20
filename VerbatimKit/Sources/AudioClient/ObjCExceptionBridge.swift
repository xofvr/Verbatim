import ObjCExceptionCatcher

struct ObjCException: Error, CustomStringConvertible {
    let name: String
    let reason: String?

    var description: String {
        if let reason {
            return "ObjC exception \(name): \(reason)"
        }
        return "ObjC exception \(name)"
    }
}

func withObjCExceptionHandling(_ body: () -> Void) throws {
    if let exception = ObjCTryCatch(body) {
        throw ObjCException(
            name: exception.name.rawValue,
            reason: exception.reason
        )
    }
}
