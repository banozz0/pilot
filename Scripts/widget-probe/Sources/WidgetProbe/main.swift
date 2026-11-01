// Widget probe (ADR 0016, pilot-1-1 T15): a locked web widget's sandbox, a see-through web view, and widget cost.
// Never draws on screen: web views live in windows that are never ordered in, or (cost --ordered) in an alpha-0,
// click-through panel parked far off every display. Network: only the local server (server.py) on 127.0.0.1.
// Re-run after each major macOS.
//   swift build --package-path Scripts/widget-probe
//   python3 -I Scripts/widget-probe/server.py <portA> <portB> <portU> <serverLog> &   (A listed, B not, U = STUN)
//   WidgetProbe sandbox <portA> <portB> <portU> <serverLog>   locked = no TCP accept, request or UDP on B or U
//   WidgetProbe glass <outDir>
//   Scripts/widget-probe/cost.sh <WidgetProbe> <outPrefix> [--ordered]
import AppKit
import SwiftUI
import WebKit

let args = CommandLine.arguments
func say(_ s: String) { print(s); fflush(stdout) }

// MARK: - Shell helpers

func sh(_ argv: [String]) async -> String {
    await Task.detached {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "run failed: \(argv[0]): \(error)" }   // the pipe's write end would never close
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }.value
}

func webKitPids() async -> Set<Int32> {
    let out = await sh(["/usr/bin/pgrep", "-f", "com.apple.WebKit"])
    return Set(out.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) })
}

func procName(_ pid: Int32) async -> String {
    let out = await sh(["/bin/ps", "-o", "comm=", "-p", "\(pid)"])
    return (out.split(separator: "/").last.map(String.init) ?? "?").trimmingCharacters(in: .whitespacesAndNewlines)
}

/// One footprint line and the last three of four `top` samples (3 s apart) per pid, all pids at once.
func measure(_ label: String, _ pids: [(String, Int32)]) async {
    say("== \(label)")
    if ProcessInfo.processInfo.environment["EXTERNAL"] != nil {   // cost.sh measures; the probe only waits
        say("PIDS " + pids.map { "\($0.0)=\($0.1)" }.joined(separator: " "))
        await sleep(22)
        return
    }
    await withTaskGroup(of: String.self) { group in
        for (name, pid) in pids {
            group.addTask {
                async let fp = sh(["/usr/bin/footprint", "-p", "\(pid)", "--noCategories"])
                async let top = sh(["/usr/bin/top", "-l", "4", "-s", "3", "-pid", "\(pid)", "-stats", "pid,cpu,mem"])
                let fpLine = (await fp).split(separator: "\n").first { $0.contains("Footprint") }.map(String.init) ?? "footprint: n/a"
                let samples = (await top).split(separator: "\n").filter { $0.hasPrefix("\(pid) ") }.suffix(3)
                return "  \(name) pid=\(pid) | \(fpLine.trimmingCharacters(in: .whitespaces)) | top cpu,mem: "
                    + samples.map { $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst().joined(separator: " ") }
                        .joined(separator: " / ")
            }
        }
        for await line in group { say(line) }
    }
}

func sleep(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

// MARK: - Scheme handler: Pilot serves a widget folder through its own scheme, CSP on every response

final class SchemeHandler: NSObject, WKURLSchemeHandler {
    var files: [String: (body: String, type: String)] = [:]   // path -> file
    var headers: [String: String] = [:]                        // on every response, refusals included
    var log: [String] = []

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let url = task.request.url!
        guard url.host == "probe", let file = files[url.path] else {
            log.append("SCHEME-REFUSED \(url.absoluteString)")
            task.didReceive(HTTPURLResponse(url: url, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: headers)!)
            task.didFinish()
            return
        }
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                        headerFields: headers.merging(["Content-Type": file.type]) { a, _ in a })!)
        task.didReceive(Data(file.body.utf8))
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class Nav: NSObject, WKNavigationDelegate, WKUIDelegate {
    var cancelForeign = true
    var log: [String] = []

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        let own = url?.scheme == "pilot-widget" || url?.scheme == "about"
        let frame = action.targetFrame?.isMainFrame == true ? "main" : "sub"
        let kind = [.linkActivated: "link", .formSubmitted: "form", .other: "other"][action.navigationType] ?? "\(action.navigationType.rawValue)"
        if own || !cancelForeign { decisionHandler(.allow); if !own { log.append("NAV-ALLOW \(frame) \(kind) \(url!.absoluteString)") } }
        else { log.append("NAV-CANCEL \(frame) \(kind) \(url?.absoluteString ?? "nil")"); decisionHandler(.cancel) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        log.append("WINDOW-OPEN-REFUSED \(action.request.url?.absoluteString ?? "nil")")
        return nil
    }
}

/// The guard: a user script in Pilot's own content world, run at document start before any widget code. The page can
/// neither see nor change that world's globals, nor post to its message handler.
final class Guard: NSObject, WKScriptMessageHandler {
    var reports: [String] = []
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        reports.append("\(message.frameInfo.isMainFrame ? "main" : "sub") \(message.body)")
    }
}

let guardWorld = WKContentWorld.world(name: "pilot-guard")
let guardSource = "window.webkit.messageHandlers.guard.postMessage("
    + "'RTCPeerConnection=' + typeof RTCPeerConnection + ' WebTransport=' + typeof WebTransport)"

/// Locked only: a link activation starts a TCP preconnect before the navigation delegate can cancel it (T15), so the
/// guard world cancels every click on a link leaving the widget before WebKit acts on it. A trusted (real) click on a
/// link is reported to Pilot, which decides; a scripted click is dropped.
let linkGuardSource = """
for (const type of ['click', 'auxclick']) window.addEventListener(type, e => {
  const a = e.target instanceof Element && e.target.closest('a, area');
  if (!a) return;
  // HTML href, SVG href or xlink:href; anything that fails to parse is treated as leaving (fail closed).
  const raw = a.getAttribute('href') ?? a.getAttributeNS('http://www.w3.org/1999/xlink', 'href');
  if (raw == null) return;
  let url = '?';
  try { url = new URL(raw, document.baseURI).href; if (url.startsWith('pilot-widget://' + location.host + '/')) return } catch (_) {}
  e.preventDefault(); e.stopImmediatePropagation();
  window.webkit.messageHandlers.guard.postMessage('LINK ' + (e.isTrusted ? 'trusted ' : 'scripted ') + url);
}, true);
"""

/// WebKit's private BOOL preferences: false when the selector is missing, so a caller can refuse to run.
@MainActor func setPref(_ prefs: WKPreferences, _ setter: String, _ on: Bool) -> Bool {
    let sel = NSSelectorFromString(setter)
    guard let m = class_getInstanceMethod(WKPreferences.self, sel) else { say("MISSING \(setter)"); return false }
    typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
    unsafeBitCast(method_getImplementation(m), to: Fn.self)(prefs, sel, on)
    return true
}

/// A WebKit feature flag through the private `_setEnabled:forFeature:`: false when the flag or the selector is missing.
@MainActor func setFeature(_ prefs: WKPreferences, _ key: String, _ on: Bool) -> Bool {
    let list = NSSelectorFromString("_features"), set = NSSelectorFromString("_setEnabled:forFeature:")
    guard WKPreferences.responds(to: list), let m = class_getInstanceMethod(WKPreferences.self, set),
          let features = (WKPreferences.self as AnyObject).perform(list)?.takeUnretainedValue() as? [NSObject],
          let feature = features.first(where: { $0.value(forKey: "key") as? String == key })
    else { say("MISSING feature \(key)"); return false }
    typealias Fn = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
    unsafeBitCast(method_getImplementation(m), to: Fn.self)(prefs, set, on, feature)
    return true
}

@MainActor func getPref(_ prefs: WKPreferences, _ getter: String) -> String {
    let sel = NSSelectorFromString(getter)
    guard let m = class_getInstanceMethod(WKPreferences.self, sel) else { return "missing" }
    typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
    return "\(unsafeBitCast(method_getImplementation(m), to: Fn.self)(prefs, sel))"
}

@MainActor func makeConfig(_ handler: SchemeHandler) -> WKWebViewConfiguration {
    let config = WKWebViewConfiguration()
    config.setURLSchemeHandler(handler, forURLScheme: "pilot-widget")
    config.websiteDataStore = .nonPersistent()
    config.preferences.isFraudulentWebsiteWarningEnabled = false   // Safe Browsing would be real network
    config.preferences.javaScriptCanOpenWindowsAutomatically = true // so window.open reaches the UI delegate
    return config
}

/// A window that is never ordered in, or (`--ordered`) an alpha-0 click-through panel at desktop level, parked far off
/// every display so nothing lands on Sven's screen.
@MainActor func host(_ view: NSView, size: NSSize, ordered: Bool) -> NSWindow {
    let w = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    w.contentView = view
    if ordered {
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        w.orderFrontRegardless()
        w.setFrameOrigin(NSPoint(x: -30000, y: -30000))   // ordering in may constrain the frame; park it again
        say("panel frame \(w.frame), on a screen: \(w.screen != nil)")
    }
    return w
}

@MainActor func load(_ wv: WKWebView, _ path: String) async {
    wv.load(URLRequest(url: URL(string: "pilot-widget://probe\(path)")!))
    for _ in 0..<100 where wv.isLoading || wv.url == nil { await sleep(0.05) }
    await sleep(0.3)
}

// MARK: - Sandbox

/// ONLY (a comma list of kind names, from the environment) narrows a run to those kinds, to pin a leak on one.
let only = ProcessInfo.processInfo.environment["ONLY"] ?? ""

func sandboxPage(mode: String, a: Int, b: Int, u: Int) -> String {
    """
    <!doctype html><html><head>
    <meta http-equiv="Content-Security-Policy" content="default-src * data: blob: 'unsafe-inline' 'unsafe-eval'; connect-src *">
    </head><body><script>
    // Hostile first move: keep the constructor, then hide it from any check made in this world.
    const RTC=window.RTCPeerConnection; try{delete window.RTCPeerConnection}catch(e){}
    // And at parse time, before anything could check it: STUN out.
    if(RTC){try{const pc=new RTC({iceServers:[{urls:'stun:127.0.0.1:\(u)'}]});pc.createDataChannel('p');pc.createOffer().then(o=>pc.setLocalDescription(o))}catch(e){}}
    const A='http://127.0.0.1:\(a)', B='http://127.0.0.1:\(b)', M='\(mode)', ONLY='\(only)';
    const on=k=>!ONLY||ONLY.split(',').includes(k);
    const q=(path,k,t)=>`/${path}?k=${k}&m=${M}&t=${t}`;
    const T=(p,ms=3000)=>Promise.race([p,new Promise(r=>setTimeout(()=>r('timeout'),ms))]);
    const add=(html)=>{const d=document.createElement('div');d.innerHTML=html;document.body.appendChild(d);return d};
    const wait=(ms,v)=>new Promise(r=>setTimeout(()=>r(v),ms));
    const kinds={
      fetch:(h,t)=>fetch(h+q('x','fetch',t)).then(r=>'ok '+r.status).catch(e=>'error: '+e.message),
      xhr:(h,t)=>new Promise(r=>{try{const x=new XMLHttpRequest();x.open('GET',h+q('x','xhr',t));x.onload=()=>r('ok '+x.status);x.onerror=()=>r('error');x.send()}catch(e){r('throw '+e.name)}}),
      websocket:(h,t)=>new Promise(r=>{try{const w=new WebSocket(h.replace('http','ws')+q('ws','websocket',t));w.onopen=()=>{r('open');w.close()};w.onerror=()=>r('error')}catch(e){r('throw '+e.name)}}),
      webtransport:(h,t)=>{if(typeof WebTransport==='undefined')return 'absent';try{const w=new WebTransport(h.replace('http','https')+q('wt','webtransport',t));return w.ready.then(()=>'ready').catch(e=>'error: '+e.message)}catch(e){return 'throw '+e.name}},
      img:(h,t)=>new Promise(r=>{const i=new Image();i.onload=()=>r('loaded');i.onerror=()=>r('error');i.src=h+q('img','img',t)}),
      script:(h,t)=>new Promise(r=>{const s=document.createElement('script');s.onload=()=>r('loaded');s.onerror=()=>r('error');s.src=h+q('script','script',t);document.head.appendChild(s)}),
      cssurl:(h,t)=>{const d=add('');d.style.cssText=`width:4px;height:4px;background-image:url(${h+q('img','cssurl',t)})`;getComputedStyle(d).backgroundImage;return wait(1500,'set')},
      cssimport:(h,t)=>{const s=document.createElement('style');s.textContent=`@import url("${h+q('css','cssimport',t)}");`;document.head.appendChild(s);return wait(1500,'set')},
      fontface:(h,t)=>{const f=new FontFace('F'+t+M,`url(${h+q('font','fontface',t)})`);return f.load().then(()=>'loaded').catch(e=>'error: '+e.name)},
      iframe:(h,t)=>new Promise(r=>{const f=document.createElement('iframe');f.onload=()=>r('load event');f.src=h+q('x','iframe',t);document.body.appendChild(f)}),
      beacon:(h,t)=>{try{return navigator.sendBeacon(h+q('x','beacon',t),'x')?'queued':'refused'}catch(e){return 'throw '+e.name}},
      eventsource:(h,t)=>new Promise(r=>{try{const e=new EventSource(h+q('x','eventsource',t));e.onopen=()=>{r('open');e.close()};e.onerror=()=>{r('error');e.close()}}catch(x){r('throw '+x.name)}}),
      audio:(h,t)=>new Promise(r=>{const a=new Audio();a.onerror=()=>r('error');a.oncanplay=()=>r('canplay');a.src=h+q('x','audio',t);a.load()}),
      video:(h,t)=>new Promise(r=>{const v=document.createElement('video');v.onerror=()=>r('error');v.oncanplay=()=>r('canplay');v.src=h+q('x','video',t);v.load()}),
      mediasource:(h,t)=>{const MS=window.ManagedMediaSource||window.MediaSource;if(!MS)return 'absent';return new Promise(r=>{const ms=new MS();const v=document.createElement('video');v.disableRemotePlayback=true;
        ms.addEventListener('sourceopen',()=>fetch(h+q('x','mediasource',t)).then(x=>r('sourceopen, fetch ok '+x.status)).catch(e=>r('sourceopen, fetch error: '+e.message)));v.src=URL.createObjectURL(ms)})},
      preconnect:(h,t)=>{add(`<link rel="preconnect" href="${h}">`);return wait(1500,'set')},
      preload:(h,t)=>{add(`<link rel="preload" as="fetch" crossorigin href="${h+q('x','preload',t)}">`);return wait(1500,'set')},
      prefetch:(h,t)=>{add(`<link rel="prefetch" href="${h+q('x','prefetch',t)}">`);return wait(1500,'set')},
      worker:(h,t)=>new Promise(r=>{try{const w=new Worker('worker.js');w.onmessage=e=>r('worker: '+e.data);w.onerror=e=>r('worker error: '+(e.message||'load'));w.postMessage(h+q('x','worker',t))}catch(e){r('throw '+e.name)}}),
      ping:(h,t)=>{const a=add(`<a href="#p${t}" ping="${h+q('x','ping',t)}">p</a>`).firstChild;a.click();return wait(1500,'clicked')},
    };
    async function runAll(){
      const out={};
      await Promise.all(Object.entries(kinds).filter(([k])=>on(k)).flatMap(([k,f])=>[['A',A],['B',B]].map(async([t,h])=>{out[k+' '+t]=String(await T(Promise.resolve(f(h,t))))})));
      if(on('redirect'))out['redirect A->B']=String(await T(fetch(A+q('redirect','redirect','A')+'&to='+encodeURIComponent(B+q('after','afterredirect','B'))).then(r=>'ok '+r.status).catch(e=>'error: '+e.message)));
      if(on('serviceworker'))out['serviceworker']=String(await T(navigator.serviceWorker?navigator.serviceWorker.register('sw.js').then(()=>'registered').catch(e=>'error: '+e.message):Promise.resolve('navigator.serviceWorker absent')));
      if(on('file'))out['file:///etc/hosts']=String(await T(fetch('file:///etc/hosts').then(r=>'ok '+r.status).catch(e=>'error: '+e.message)));
      if(on('other'))out['other widget']=String(await T(fetch('pilot-widget://other/index.html').then(r=>'status '+r.status).catch(e=>'error: '+e.message)));
      if(on('webrtc'))out['webrtc (saved constructor)']=String(await T((async()=>{
        if(typeof RTC==='undefined')return 'RTCPeerConnection absent';
        try{const pc=new RTC({iceServers:[{urls:'stun:127.0.0.1:\(u)'}]});pc.createDataChannel('x');
          await pc.setLocalDescription(await pc.createOffer());await new Promise(r=>setTimeout(r,2000));pc.close();return 'gathered'}catch(e){return 'throw '+e.name+' '+e.message}})(),4000));
      if(on('windowopen'))try{window.open(B+q('x','windowopen','B'))}catch(e){out['window.open']='throw '+e.name}
      return JSON.stringify(out);
    }
    // Leaving steps, run one at a time after runAll: each ends the page when allowed.
    function linkClick(){const a=add(`<a href="${B+q('x','linkclick','B')}">go</a>`).firstChild;a.click()}
    const click=el=>el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true}));
    function svgLink(){click(add(`<svg width="10" height="10"><a href="${B+q('x','svglink','B')}"><rect width="10" height="10"/></a></svg>`).querySelector('a'))}
    function xlinkLink(){click(add(`<svg width="10" height="10"><a xlink:href="${B+q('x','xlinklink','B')}"><rect width="10" height="10"/></a></svg>`).querySelector('a'))}
    function srcdocLink(){const f=document.createElement('iframe');f.srcdoc=`<a href="${B+q('x','srcdoclink','B')}">go</a>`;f.onload=()=>f.contentDocument.querySelector('a').click();document.body.appendChild(f)}
    function blankLink(){const f=document.createElement('iframe');document.body.appendChild(f);const d=f.contentDocument;d.body.innerHTML=`<a target="_top" href="${B+q('x','blanklink','B')}">go</a>`;d.querySelector('a').click()}
    if(ONLY==='linkonload')setTimeout(linkClick,1500);   // no user gesture can be live at load
    function formSubmit(){const f=add(`<form method="post" action="${B+q('x','form','B')}"><input name="v" value="1"></form>`).firstChild;f.submit()}
    </script></body></html>
    """
}

let workerJS = "onmessage=e=>fetch(e.data).then(r=>postMessage('ok '+r.status)).catch(x=>postMessage('error: '+x.message))"
let serviceWorkerJS = "self.addEventListener('install',()=>fetch(self.location.origin))"

@MainActor func runSandbox() async {
    let a = Int(args[2])!, b = Int(args[3])!, u = Int(args[4])!, serverLog = args[5]
    let listed = "http://127.0.0.1:\(a)"
    let csp = "default-src 'self' \(listed) ws://127.0.0.1:\(a); script-src 'self' 'unsafe-inline' \(listed); "
        + "style-src 'self' 'unsafe-inline' \(listed); img-src 'self' data: \(listed); object-src 'none'; base-uri 'none'; form-action 'none'"
    let rulesJSON = """
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^pilot-widget://probe/"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^https?://127\\\\.0\\\\.0\\\\.1:\(a)/"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^wss?://127\\\\.0\\\\.0\\\\.1:\(a)/"},"action":{"type":"ignore-previous-rules"}}]
    """
    // A locked widget never runs without its rule list: no list, no locked modes.
    var rules: WKContentRuleList?
    do { rules = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "t15-probe", encodedContentRuleList: rulesJSON) }
    catch { say("RULES COMPILE FAILED, locked modes refused: \(error)") }
    say("CSP header (every response): \(csp)")
    say("Rule list: block .*, except ^pilot-widget://probe/ and ^(https?|wss?)://127.0.0.1:\(a)/")
    let defaults = WKPreferences()
    say("defaults: _peerConnectionEnabled=\(getPref(defaults, "_peerConnectionEnabled")) "
        + "_dnsPrefetchingEnabled=\(getPref(defaults, "_dnsPrefetchingEnabled")) "
        + "_hyperlinkAuditingEnabled=\(getPref(defaults, "_hyperlinkAuditingEnabled"))")

    let modes = ProcessInfo.processInfo.environment["MODES"].map { $0.split(separator: ",").map(String.init) }
        ?? ["none", "csp", "rules", "both", "locked", "locked-rtc-on"]
    for mode in modes {
        let handler = SchemeHandler()
        handler.files["/index.html"] = (sandboxPage(mode: mode, a: a, b: b, u: u), "text/html; charset=utf-8")
        handler.files["/worker.js"] = (workerJS, "text/javascript")
        handler.files["/sw.js"] = (serviceWorkerJS, "text/javascript")
        handler.files["/__guard.html"] = ("<!doctype html><title>Pilot</title>", "text/html; charset=utf-8")   // Pilot's own
        // locked-rtc-on: the full lock with the peer-connection switch left on, as if it had stopped working.
        let locked = mode.hasPrefix("locked")
        if mode == "csp" || mode == "both" || locked { handler.headers["Content-Security-Policy"] = csp }
        let config = makeConfig(handler)
        let guardian = Guard()
        config.userContentController.add(guardian, contentWorld: guardWorld, name: "guard")
        config.userContentController.addUserScript(WKUserScript(source: guardSource, injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: false, in: guardWorld))
        say("\n#### mode=\(mode)")
        if mode == "rules" || mode == "both" || locked {
            guard let rules else { say("  REFUSED: no rule list"); continue }
            config.userContentController.add(rules)
        }
        if locked {
            handler.headers["X-DNS-Prefetch-Control"] = "off"
            let set = (mode == "locked-rtc-on" || setPref(config.preferences, "_setPeerConnectionEnabled:", false))
                && setPref(config.preferences, "_setDNSPrefetchingEnabled:", false)
                && setFeature(config.preferences, "WebTransportEnabled", false)
            guard set else { say("  REFUSED: a private switch is missing"); continue }
            config.userContentController.addUserScript(WKUserScript(source: linkGuardSource, injectionTime: .atDocumentStart,
                                                                    forMainFrameOnly: false, in: guardWorld))
        }
        let nav = Nav()
        nav.cancelForeign = mode != "none"
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), configuration: config)
        wv.navigationDelegate = nav
        wv.uiDelegate = nav
        let win = host(wv, size: wv.frame.size, ordered: false)
        let started = Date().timeIntervalSince1970
        // Preflight: Pilot's own blank page loads first in the same web view; the guard's report from it decides whether
        // the widget's index.html loads at all, so no widget code runs before the check.
        await load(wv, "/__guard.html")
        let mainGuard = guardian.reports.first { $0.hasPrefix("main") } ?? "no report"
        let refuse = mainGuard == "no report" || !mainGuard.contains("RTCPeerConnection=undefined")
            || !mainGuard.contains("WebTransport=undefined")
        say("  guard on Pilot's blank page (pilot-guard world): \(mainGuard) -> a locked widget would be \(refuse ? "REFUSED" : "shown")")
        if locked && refuse {
            say("  REFUSED before widget code: index.html never loads")
        } else {
            await load(wv, "/index.html")
            let pageSays = (try? await wv.evaluateJavaScript("typeof RTCPeerConnection")) as? String ?? "?"
            say("  page-world check after load: typeof RTCPeerConnection = \(pageSays)")
            do {
                let json = try await wv.callAsyncJavaScript("return await runAll()", contentWorld: .page) as? String ?? "{}"
                let dict = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: String] ?? [:]
                for k in dict.keys.sorted() { say("  page: \(k) -> \(dict[k]!)") }
            } catch { say("  runAll failed: \(error)") }
            let steps = [("svglink", "svgLink()"), ("xlinklink", "xlinkLink()"), ("srcdoclink", "srcdocLink()"), ("blanklink", "blankLink()"),
                         ("linkclick", "linkClick()"), ("linktimer", "setTimeout(linkClick, 0)"), ("form", "formSubmit()"),
                         ("navigate", "location.href='http://127.0.0.1:\(b)/x?k=navigate&m=\(mode)&t=B'")]
            for (name, step) in steps where only.isEmpty || only.split(separator: ",").contains(Substring(name)) {
                _ = try? await wv.evaluateJavaScript("\(step); 1")
                await sleep(1.5)
            }
        }
        win.close()
        config.userContentController.removeAllContentRuleLists()
        await sleep(2)   // a late request still lands in this mode's window
        let ended = Date().timeIntervalSince1970
        for l in nav.log + handler.log + guardian.reports.dropFirst() { say("  probe: \(l)") }
        let lines = ((try? String(contentsOfFile: serverLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        let inWindow = lines.filter { (Double($0.split(separator: " ")[0]) ?? 0) >= started && (Double($0.split(separator: " ")[0]) ?? 0) <= ended }
        for h in inWindow where !h.contains("port=A") { say("  server: \(h.split(separator: " ").dropFirst().joined(separator: " "))") }
        // QUIC retransmits from an earlier mode's socket keep arriving for seconds after its web view is gone: a UDP
        // line counts only when its source port was not seen before this mode started.
        let port = { (l: String) in l.components(separatedBy: "from=").last ?? "" }
        let earlier = Set(lines.filter { (Double($0.split(separator: " ")[0]) ?? 0) < started && $0.contains(" UDP ") }.map(port))
        let carried = inWindow.filter { $0.contains(" UDP ") && earlier.contains(port($0)) }.count
        func n(_ s: String) -> Int { inWindow.filter { $0.contains(s) && !($0.contains(" UDP ") && earlier.contains(port($0))) }.count }
        say("  COUNTS mode=\(mode): A accept=\(n("ACCEPT port=A")) http=\(n("HIT port=A method=")) udp=\(n("UDP port=A")) | "
            + "B accept=\(n("ACCEPT port=B")) http=\(n("HIT port=B method=")) udp=\(n("UDP port=B")) | U udp=\(n("UDP port=U")) "
            + "| earlier flows' UDP=\(carried)")
    }
    try? await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: "t15-probe")
}

// MARK: - Glass: is the web view see-through?

let widgetHTML = """
<!doctype html><html><head><style>
html,body{margin:0;background:transparent;font:600 13px -apple-system,system-ui;color:#fff}
.card{position:absolute;left:40px;top:30px;width:240px;height:140px;border-radius:18px;background:rgba(255,255,255,.18);
 border:1px solid rgba(255,255,255,.35);padding:14px 16px;box-sizing:border-box}
.big{font-size:34px;font-weight:700} .row{display:flex;justify-content:space-between;opacity:.9;margin-top:6px}
.bar{height:6px;border-radius:3px;background:rgba(255,255,255,.25);margin-top:10px}.bar i{display:block;height:6px;width:42%;border-radius:3px;background:#fff}
</style></head><body><div class="card"><div class="big" id="cpu">12%</div>
<div class="row"><span>Memory</span><span id="mem">9.1 GB</span></div><div class="row"><span>Time</span><span id="time">--</span></div>
<div class="bar"><i id="bar"></i></div></div><script>
window.update=d=>{cpu.textContent=d.cpu+'%';mem.textContent=d.mem;bar.style.width=d.cpu+'%'};
window.startClock=()=>setInterval(()=>{time.textContent=new Date().toLocaleTimeString()},1000);
</script></body></html>
"""

func rgba(_ image: NSImage) -> (CGContext, Int, Int)? {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    return (ctx, cg.width, cg.height)
}

func alpha(_ c: (CGContext, Int, Int), fx: Double, fy: Double) -> UInt8 {
    let (ctx, w, h) = c
    let x = Int(Double(w) * fx), y = Int(Double(h) * fy)
    return ctx.data!.load(fromByteOffset: (y * w + x) * 4 + 3, as: UInt8.self)
}

@MainActor func runGlass() async {
    let outDir = args[2]
    var shots: [(String, NSImage)] = []
    for transparent in [false, true] {
        let handler = SchemeHandler()
        handler.files["/index.html"] = (widgetHTML, "text/html; charset=utf-8")
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), configuration: makeConfig(handler))
        if transparent {
            // Private on WKWebView: the public drawsBackground is WebKit1's WebView only (SDK WebView.h).
            wv.setValue(false, forKey: "drawsBackground")
            say("drawsBackground after KVC set: \(String(describing: wv.value(forKey: "drawsBackground")))")
        }
        let win = host(wv, size: wv.frame.size, ordered: false)
        await load(wv, "/index.html")
        await sleep(0.5)
        do {
            let img = try await wv.takeSnapshot(configuration: nil)
            let label = transparent ? "drawsBackground=false" : "default"
            if let c = rgba(img) {
                say("snapshot \(label): \(c.1)x\(c.2) px, alpha at empty corner=\(alpha(c, fx: 0.03, fy: 0.03)), "
                    + "alpha inside the card=\(alpha(c, fx: 0.5, fy: 0.5))")
            }
            shots.append((label, img))
            try img.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }?
                .write(to: URL(fileURLWithPath: "\(outDir)/snapshot-\(transparent ? "transparent" : "default").png"))
        } catch { say("snapshot failed (transparent=\(transparent)): \(error)") }
        win.close()
    }
    // Composite both snapshots over a busy stand-in backdrop (a gradient with stripes): the glass itself does not
    // render offscreen (Memory/Mac/liquid-glass-no-offscreen-check), so this proves see-through only.
    guard shots.count == 2, let first = rgba(shots[0].1) else { return }
    let w = first.1, h = first.2, gap = 20
    let ctx = CGContext(data: nil, width: w * 2 + gap, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
        CGColor(red: 0.95, green: 0.35, blue: 0.3, alpha: 1), CGColor(red: 0.25, green: 0.3, blue: 0.9, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: w * 2 + gap, y: h), options: [])
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.25))
    for i in stride(from: 0, to: w * 2 + gap, by: 36) { ctx.fill(CGRect(x: i, y: 0, width: 12, height: h)) }
    for (i, shot) in shots.enumerated() {
        if let cg = shot.1.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.draw(cg, in: CGRect(x: i * (w + gap), y: 0, width: w, height: h))
        }
    }
    let path = "\(outDir)/glass-composite.png"
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    say("composite: \(path) (left: default web view, right: drawsBackground=false)")
}

// MARK: - Cost

final class StatsModel: ObservableObject { @Published var cpu = 12; @Published var mem = "9.1 GB" }

struct BlocksStandIn: View {
    @ObservedObject var model: StatsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This Mac").font(.headline)
            Text("\(model.cpu)%").font(.system(size: 34, weight: .bold))
            HStack { Text("Memory"); Spacer(); Text(model.mem) }
            HStack { Text("Disk"); Spacer(); Text("212 GB free") }
            Gauge(value: Double(model.cpu), in: 0...100) { EmptyView() }
        }
        .padding(14).frame(width: 240, height: 160)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.18)))
    }
}

@MainActor func runCost() async {
    let ordered = args.contains("--ordered")
    let me = ProcessInfo.processInfo.processIdentifier
    say("cost probe pid=\(me) ordered=\(ordered)")
    await sleep(3)
    await measure("0 baseline: probe only, AppKit + WebKit linked, no view", [("probe", me)])

    let model = StatsModel()
    let hosting = NSHostingView(rootView: BlocksStandIn(model: model))
    hosting.frame = NSRect(x: 0, y: 0, width: 240, height: 160)
    let blocksWin = host(hosting, size: hosting.frame.size, ordered: ordered)
    let tick = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in model.cpu = Int.random(in: 5...60) }
    await sleep(8)
    await measure("1 one blocks widget (NSHostingView stand-in, data every 10 s)", [("probe", me)])

    let before = await webKitPids()
    var views: [WKWebView] = []
    var wins: [NSWindow] = []
    func addWeb() async {
        let handler = SchemeHandler()
        handler.files["/index.html"] = (widgetHTML, "text/html; charset=utf-8")
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), configuration: makeConfig(handler))
        wv.setValue(false, forKey: "drawsBackground")
        wins.append(host(wv, size: wv.frame.size, ordered: ordered))
        await load(wv, "/index.html")
        views.append(wv)
    }
    func helpers() async -> [(String, Int32)] {
        var out: [(String, Int32)] = [("probe", me)]
        for p in (await webKitPids()).subtracting(before).sorted() { out.append((await procName(p), p)) }
        return out
    }
    let push = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
        for wv in views { wv.evaluateJavaScript("update({cpu:\(Int.random(in: 5...60)),mem:'9.\(Int.random(in: 0...9)) GB'})") }
    }
    await addWeb()
    let vis = (try? await views[0].evaluateJavaScript("document.visibilityState")) as? String ?? "?"
    say("web widget 1: WebContent pid=\(views[0].value(forKey: "_webProcessIdentifier") ?? "?"), document.visibilityState=\(vis)")
    await sleep(8)
    await measure("2 + one web widget (static page, data pushed every 10 s)", await helpers())

    await addWeb()
    say("web widget 2: WebContent pid=\(views[1].value(forKey: "_webProcessIdentifier") ?? "?")")
    await sleep(8)
    await measure("3 + a second web widget", await helpers())

    for wv in views { _ = try? await wv.evaluateJavaScript("startClock(); 1") }
    await sleep(8)
    await measure("4 both web widgets running a 1 s clock", await helpers())
    tick.invalidate(); push.invalidate()
    for w in wins { w.close() }
    blocksWin.close()
}

// MARK: - Main

NSApplication.shared.setActivationPolicy(.prohibited)
Task { @MainActor in
    switch args.count > 1 ? args[1] : "" {
    case "sandbox": await runSandbox()
    case "glass": await runGlass()
    case "cost": await runCost()
    default: say("usage: WidgetProbe sandbox|glass|cost")
    }
    exit(0)
}
NSApplication.shared.run()
