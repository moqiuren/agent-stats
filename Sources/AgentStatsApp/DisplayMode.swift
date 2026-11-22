import StatsCore
import StatsAdapters
import AppKit

enum StatsDisplayMode:String,CaseIterable {
 case floating,menuBar
 var title:String{self == .floating ? "悬浮条":"菜单栏"}
}

struct StatsInspectorContext {
 let anchor:NSView
 let host:NSRect
 let screen:NSRect
 let bar:NSRect
 var isMenuBar:Bool=false
}

// A native menu item carries its own destination instead of asking the app to
// remember which level the user is browsing.
final class StatsSessionMenuItem:NSObject {
 let project:String?
 let session:String
 init(project:String?,session:String){self.project=project;self.session=session}
}
