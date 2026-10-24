import AppKit
import SwiftUI
import WebKit

// local file image that tolerates missing paths
struct FileImage: View {
    let path: String?
    var body: some View {
        if let path, let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image).resizable()
        } else {
            Color.clear
        }
    }
}

// the official backgrounds are 16:9, both the still and the video share one aspect-fill frame
struct BackgroundStack: View {
    let art: Art?
    let paused: Bool
    @State private var loop: URL?
    @State private var webFallback = false

    var body: some View {
        GeometryReader { geo in
            let size = fillSize(for: geo.size)
            ZStack {
                Color.zzzPanel
                FileImage(path: art?.local.background)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                if let loop {
                    LoopPlayerView(url: loop, paused: paused)
                        .frame(width: size.width, height: size.height)
                        .allowsHitTesting(false)
                } else if webFallback, let src = art?.local.video.map({ URL(fileURLWithPath: $0) }) {
                    VideoLayer(source: src, paused: paused)
                        .frame(width: size.width, height: size.height)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        // the still image covers the second or so the one-time transcode takes
        .task(id: art?.local.video) {
            guard let webm = art?.local.video else { return }
            do {
                let url = try await Task.detached(priority: .utility) { try await LoopTranscoder.transcode(webm: webm) }.value
                loop = url
                webFallback = false
            } catch {
                NSLog("asahiro: background transcode failed, using webkit: \(error)")
                loop = nil
                webFallback = true
            }
        }
    }

    private func fillSize(for container: CGSize) -> CGSize {
        let ratio: CGFloat = 16.0 / 9.0
        if container.width / max(container.height, 1) > ratio {
            return CGSize(width: container.width, height: container.width / ratio)
        }
        return CGSize(width: container.height * ratio, height: container.height)
    }
}

private final class PassthroughWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// webkit decodes the webm backgrounds, avfoundation does not. two decoders ping-pong so the
// next one is already sitting on frame 0 when the current one shows its last frame
struct VideoLayer: NSViewRepresentable {
    let source: URL
    let paused: Bool

    final class Coordinator {
        var loaded: URL?
        var paused: Bool?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let conf = WKWebViewConfiguration()
        conf.mediaTypesRequiringUserActionForPlayback = []
        let view = PassthroughWebView(frame: .zero, configuration: conf)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if context.coordinator.loaded != source {
            context.coordinator.loaded = source
            context.coordinator.paused = nil
            load(source, into: view)
        }
        if context.coordinator.paused != paused {
            context.coordinator.paused = paused
            view.evaluateJavaScript("window.setWanted && setWanted(\(!paused))")
        }
    }

    private func load(_ src: URL, into view: WKWebView) {
        let html = """
        <!doctype html><html><head><style>
        html,body{margin:0;height:100%;background:transparent;overflow:hidden}
        video{position:fixed;inset:0;width:100%;height:100%;object-fit:cover;opacity:0}
        video.top{opacity:1;z-index:2}
        video.fade{transition:opacity .35s ease-out}
        </style></head><body>
        <video id="a" class="fade" muted playsinline preload="auto" src="\(src.absoluteString)"></video>
        <video id="b" muted playsinline preload="auto" src="\(src.absoluteString)"></video>
        <script>
        let cur=document.getElementById('a'), next=document.getElementById('b');
        let wanted=\(!paused), swapping=false;
        const frame=1/30;
        function arm(v){ v.requestVideoFrameCallback(tick); }
        function tick(now, meta){
          if(cur.duration && meta.mediaTime >= cur.duration - frame*1.5){ swap(); return; }
          arm(cur);
        }
        function swap(){
          if(swapping) return; swapping=true;
          const incoming=next, outgoing=cur;
          incoming.currentTime=0;
          incoming.play().then(()=>{
            incoming.requestVideoFrameCallback(()=>{
              incoming.classList.add('top'); outgoing.classList.remove('top');
              cur=incoming; next=outgoing; swapping=false;
              outgoing.pause(); outgoing.currentTime=0;
              arm(cur);
            });
          }).catch(()=>{ swapping=false; });
        }
        // only the very first appearance fades in, loop swaps must be instant
        cur.addEventListener('playing',()=>{ cur.classList.add('top'); setTimeout(()=>cur.classList.remove('fade'),400); },{once:true});
        // webkit occasionally suspends background media on its own, resume unless we asked for a pause
        const kick=()=>{ if(wanted && cur.paused && !swapping){ cur.play().catch(()=>{}); } };
        ['pause','stalled','suspend'].forEach(e=>{ document.getElementById('a').addEventListener(e,()=>setTimeout(kick,200)); document.getElementById('b').addEventListener(e,()=>setTimeout(kick,200)); });
        document.addEventListener('visibilitychange',kick);
        setInterval(kick,2000);
        window.setWanted=(on)=>{ wanted=on; if(on){ kick(); } else { cur.pause(); } };
        if(wanted){ cur.play().catch(()=>{}); }
        arm(cur);
        </script>
        </body></html>
        """
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Asahiro/art")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let page = dir.appendingPathComponent("background.html")
        do {
            try html.write(to: page, atomically: true, encoding: .utf8)
            view.loadFileURL(page, allowingReadAccessTo: dir)
        } catch {
            view.loadHTMLString(html, baseURL: nil)
        }
    }
}

// the official theme overlay bakes both logos onto a dark panel. this keys the panel colour out
// (colour-to-alpha) and splits what is left into the game logo and the update block, so the
// launcher can place and scale them itself
struct ThemeParts {
    let gameLogo: NSImage
    let updateBlock: NSImage?

    private static let panel: (Double, Double, Double) = (14, 18, 17)

    static func load(themePath: String) -> ThemeParts? {
        let src = URL(fileURLWithPath: themePath)
        let dir = src.deletingLastPathComponent().appendingPathComponent("parts-" + src.deletingPathExtension().lastPathComponent)
        let logoURL = dir.appendingPathComponent("mark.png")
        let updateURL = dir.appendingPathComponent("update.png")
        if let logo = NSImage(contentsOf: logoURL) {
            return ThemeParts(gameLogo: logo, updateBlock: NSImage(contentsOf: updateURL))
        }
        guard let image = NSImage(contentsOf: src),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let parts = extract(cg) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        write(parts.0, to: logoURL)
        if let update = parts.1 { write(update, to: updateURL) }
        return ThemeParts(gameLogo: NSImage(cgImage: parts.0, size: .zero),
                          updateBlock: parts.1.map { NSImage(cgImage: $0, size: .zero) })
    }

    private static func write(_ cg: CGImage, to url: URL) {
        guard let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    private static func extract(_ cg: CGImage) -> (CGImage, CGImage?)? {
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard w > 0, h > 0, let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var out = [UInt8](repeating: 0, count: w * h * 4)
        var rowHasLogo = [Bool](repeating: false, count: h)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let a = Double(px[i + 3]) / 255
                if a < 0.02 { continue }
                let c = [Double(px[i]) / a, Double(px[i + 1]) / a, Double(px[i + 2]) / a]
                let k = [panel.0, panel.1, panel.2]
                var ca = 0.0
                for j in 0..<3 {
                    let d = c[j] - k[j]
                    ca = max(ca, d > 0 ? d / (255 - k[j]) : -d / k[j])
                }
                ca = min(1, ca)
                let alpha = ca * a
                if alpha < 0.03 { continue }
                for j in 0..<3 {
                    let fg = min(255, max(0, k[j] + (c[j] - k[j]) / ca))
                    out[i + j] = UInt8(fg * alpha)
                }
                out[i + 3] = UInt8(alpha * 255)
                if alpha > 0.5 { rowHasLogo[y] = true }
            }
        }

        // rows separated by a clear gap form bands, the first is the game logo
        var bands: [Range<Int>] = []
        var start: Int?
        var gap = 0
        for y in 0..<h {
            if rowHasLogo[y] {
                if start == nil { start = y }
                gap = 0
            } else if let s = start {
                gap += 1
                if gap > h / 60 {
                    bands.append(s..<(y - gap + 1))
                    start = nil
                }
            }
        }
        if let s = start { bands.append(s..<h) }
        bands = bands.filter { $0.count > h / 100 }
        guard let first = bands.first else { return nil }

        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let keyed = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }

        // with firstCluster the crop stops at the first clear vertical gap, which isolates the z mark
        func crop(_ rows: Range<Int>, firstCluster: Bool = false) -> CGImage? {
            var solid = [Bool](repeating: false, count: w)
            for y in rows {
                // only solid pixels count, faint keying noise near the panel's faded edge would widen the box
                for x in 0..<w where out[(y * w + x) * 4 + 3] > 90 { solid[x] = true }
            }
            guard let minX = solid.firstIndex(of: true) else { return nil }
            var maxX = solid.lastIndex(of: true) ?? minX
            if firstCluster {
                var gap = 0
                for x in minX..<w {
                    if solid[x] {
                        maxX = x
                        gap = 0
                    } else {
                        gap += 1
                        if gap > rows.count / 4 { break }
                    }
                }
            }
            guard maxX > minX else { return nil }
            let pad = 4
            let rect = CGRect(x: max(0, minX - pad), y: max(0, rows.lowerBound - pad),
                              width: min(w, maxX + pad) - max(0, minX - pad),
                              height: min(h, rows.upperBound + pad) - max(0, rows.lowerBound - pad))
            return keyed.cropping(to: rect)
        }

        guard let logo = crop(first, firstCluster: true) else { return nil }
        let rest = bands.dropFirst()
        let update = rest.first.flatMap { f in crop(f.lowerBound..<(rest.last?.upperBound ?? f.upperBound)) }
        return (logo, update)
    }
}
