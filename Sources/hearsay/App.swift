import AppKit

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--audio-probe" { exit(AudioProbe.run(arguments: Array(args.dropFirst()))) }
        Log.start(role: "app")
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    override init() { super.init(); AppDelegate.shared = self }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("launched")
    }
}
