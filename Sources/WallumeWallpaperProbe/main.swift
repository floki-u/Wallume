import Foundation
import WallumeWallpaperPOC

let report = WallpaperExtensionRuntimeProbe().inspect()
let payload: [String: Any] = [
    "mode": "read-only-runtime-probe",
    "frameworkPath": WallpaperExtensionRuntimeProbe.frameworkPath,
    "frameworkLoaded": report.frameworkLoaded,
    "availableClasses": report.availableClasses,
    "missingClasses": report.missingClasses,
    "compatible": report.isCompatible,
]

let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([0x0A]))
