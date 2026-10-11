import AppKit
let destination = CommandLine.arguments[1]
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = CGFloat(pixels)
        let shape = NSBezierPath(roundedRect: NSRect(x: s*0.08,y: s*0.08,width: s*0.84,height:s*0.84), xRadius:s*0.2, yRadius:s*0.2)
        NSGradient(starting: NSColor(srgbRed:0.08,green:0.26,blue:0.28,alpha:1), ending:NSColor(srgbRed:0.05,green:0.13,blue:0.18,alpha:1))!.draw(in:shape,angle:90)
        let shield = NSBezierPath()
        shield.move(to:NSPoint(x:s*0.50,y:s*0.78))
        shield.curve(to:NSPoint(x:s*0.27,y:s*0.68),controlPoint1:NSPoint(x:s*0.41,y:s*0.70),controlPoint2:NSPoint(x:s*0.33,y:s*0.68))
        shield.line(to:NSPoint(x:s*0.27,y:s*0.49))
        shield.curve(to:NSPoint(x:s*0.50,y:s*0.23),controlPoint1:NSPoint(x:s*0.27,y:s*0.35),controlPoint2:NSPoint(x:s*0.38,y:s*0.27))
        shield.curve(to:NSPoint(x:s*0.73,y:s*0.49),controlPoint1:NSPoint(x:s*0.62,y:s*0.27),controlPoint2:NSPoint(x:s*0.73,y:s*0.35))
        shield.line(to:NSPoint(x:s*0.73,y:s*0.68))
        shield.curve(to:NSPoint(x:s*0.50,y:s*0.78),controlPoint1:NSPoint(x:s*0.67,y:s*0.68),controlPoint2:NSPoint(x:s*0.59,y:s*0.70))
        NSColor(srgbRed:0.49,green:0.88,blue:0.72,alpha:1).setFill(); shield.fill()
        let check = NSBezierPath()
        check.move(to:NSPoint(x:s*0.38,y:s*0.51)); check.line(to:NSPoint(x:s*0.47,y:s*0.43)); check.line(to:NSPoint(x:s*0.64,y:s*0.61))
        check.lineWidth = s*0.055; check.lineCapStyle = .round; check.lineJoinStyle = .round
        NSColor(srgbRed:0.06,green:0.20,blue:0.23,alpha:1).setStroke(); check.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:destination).appendingPathComponent(filename))
    }
}
