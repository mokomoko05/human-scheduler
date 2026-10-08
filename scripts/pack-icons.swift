import Foundation

let source = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
let entries = [
    ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"),
    ("ic12", "icon_32x32@2x.png"), ("ic13", "icon_128x128@2x.png"),
    ("ic14", "icon_256x256@2x.png")
]

func sizeBytes(_ count: Int) -> Data {
    var value = UInt32(count).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}

var contents = Data()
for (type, filename) in entries {
    let png = try Data(contentsOf: source.appendingPathComponent(filename))
    contents.append(Data(type.utf8))
    contents.append(sizeBytes(png.count + 8))
    contents.append(png)
}
var icon = Data("icns".utf8)
icon.append(sizeBytes(contents.count + 8))
icon.append(contents)
try icon.write(to: destination)
