import AppKit

let destination = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(srgbRed: 36.0 / 255, green: 41.0 / 255, blue: 47.0 / 255, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 205, yRadius: 205).fill()
NSColor.white.setFill()
NSBezierPath(roundedRect: NSRect(x: 230, y: 208, width: 564, height: 618), xRadius: 64, yRadius: 64).fill()
NSColor(srgbRed: 208.0 / 255, green: 215.0 / 255, blue: 222.0 / 255, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 295, y: 670, width: 434, height: 36), xRadius: 18, yRadius: 18).fill()
let check = NSBezierPath()
check.move(to: NSPoint(x: 350, y: 455))
check.line(to: NSPoint(x: 465, y: 346))
check.line(to: NSPoint(x: 678, y: 562))
check.lineWidth = 55
check.lineCapStyle = .round
check.lineJoinStyle = .round
NSColor(srgbRed: 26.0 / 255, green: 127.0 / 255, blue: 55.0 / 255, alpha: 1).setStroke()
check.stroke()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
