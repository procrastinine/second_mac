import Foundation
import NetFS

// Credentials arrive on stdin, never in process arguments, URLs or logs.
struct Request: Decodable {
    let user: String
    let password: String
    let port: Int
    let mount: String
}
do {
    let request = try JSONDecoder().decode(Request.self, from: FileHandle.standardInput.readDataToEndOfFile())
    guard (1024...65535).contains(request.port),
          let url = URL(string: "smb://127.0.0.1:\(request.port)/Root") else {
        throw NSError(domain: "AgentVM", code: Int(EINVAL))
    }
    let openOptions = NSMutableDictionary(dictionary: [
        kNAUIOptionKey: kNAUIOptionNoUI,
        kNetFSAllowLoopbackKey: true,
        kNetFSForceNewSessionKey: true
    ])
    let mountOptions = NSMutableDictionary(dictionary: [kNetFSMountAtMountDirKey: true])
    var mounts: Unmanaged<CFArray>?
    let result = NetFSMountURLSync(url as CFURL, URL(fileURLWithPath: request.mount) as CFURL,
                                  request.user as CFString, request.password as CFString,
                                  openOptions, mountOptions, &mounts)
    _ = mounts?.takeRetainedValue()
    guard result == 0 else {
        FileHandle.standardError.write(Data("Native file mount failed (code \(result)).\n".utf8))
        exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("Cannot mount guest files: invalid input or system error.\n".utf8))
    exit(1)
}
