import Cocoa
import WebKit

final class WebAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let raw = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "http://127.0.0.1:8188"
        guard let url = URL(string: raw),
              let host = url.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost" else {
            let alert = NSAlert()
            alert.messageText = "AI Studio Web"
            alert.informativeText = "Only localhost URLs are allowed (127.0.0.1 or localhost)."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.load(URLRequest(url: url))

        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        let title: String
        switch port {
        case 8188:
            title = "ComfyUI"
        case 8080:
            title = "Open WebUI"
        default:
            title = "AI Studio Web"
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = title
        win.contentView = webView
        win.center()
        win.makeKeyAndOrderFront(nil)
        window = win
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
let delegate = WebAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()