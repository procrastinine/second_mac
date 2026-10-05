import Foundation
import Virtualization

// Read metadata only; Tart owns the resumable download and OS installation.
func report(_ result: Result<VZMacOSRestoreImage, Error>) {
    do {
        let image = try result.get()
        guard image.isSupported else {
            throw NSError(domain: "SecondMac", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The selected restore image is not supported on this Mac."])
        }
        let os = image.operatingSystemVersion
        let metadata = ["url": image.url.absoluteString,
                        "version": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                        "build": image.buildVersion]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(1)
    }
}
if CommandLine.arguments.count == 2 {
    VZMacOSRestoreImage.load(from: URL(fileURLWithPath: CommandLine.arguments[1]), completionHandler: report)
} else if CommandLine.arguments.count == 1 {
    VZMacOSRestoreImage.fetchLatestSupported(completionHandler: report)
} else {
    fputs("Expected no arguments (latest metadata), or one local IPSW path.\n", stderr)
    exit(2)
}
dispatchMain()
