import Foundation

/// Compatibility shim replacing the ObjC exception catcher.
/// Since we've removed ObjC from kht_bridge, this simply executes the block directly.
/// ObjC exceptions from other frameworks will not be caught — but in practice
/// the callers (shellOut to /usr/bin/top) don't throw ObjC exceptions.
public enum ObjC {
    public static func catchException(_ block: () throws -> Void) throws {
        try block()
    }
}
