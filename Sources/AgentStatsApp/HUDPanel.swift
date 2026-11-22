import StatsCore
import StatsAdapters
import AppKit
final class HUDPanel:NSPanel {
 // Activated only while the host passes foreground/main-window validation.
 // One level above normal prevents host clicks from covering the overlay.
 static let hostOverlayLevel=NSWindow.Level(rawValue:NSWindow.Level.normal.rawValue+1)
 func setHostOverlayActive(_ active:Bool){
  let desired=active ? Self.hostOverlayLevel:NSWindow.Level.normal
  if level != desired{level=desired}
 }
 override var canBecomeKey:Bool{true}
 override var canBecomeMain:Bool{false}
}
