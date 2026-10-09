import SwiftUI
import AppKit
import Combine

// MARK: - Theme (colors the user can change)

struct HSB: Codable, Equatable {
    var h: Double, s: Double, b: Double
    var color: Color { Color(hue: h, saturation: s, brightness: b) }
    var luminance: Double {
        guard let c = NSColor(hue: h, saturation: s, brightness: b, alpha: 1).usingColorSpace(.sRGB) else { return 0 }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    }
}

struct Theme: Codable, Equatable {
    var name: String
    var bg: HSB
    var accent: HSB
    var opacity: Double

    static let presets: [Theme] = [
        Theme(name: "Midnight", bg: HSB(h: 0.64, s: 0.50, b: 0.14), accent: HSB(h: 0.42, s: 0.70, b: 0.95), opacity: 0.97),
        Theme(name: "Hyperpop", bg: HSB(h: 0.80, s: 0.60, b: 0.14), accent: HSB(h: 0.90, s: 0.55, b: 1.0), opacity: 0.97),
        Theme(name: "Paper", bg: HSB(h: 0.11, s: 0.05, b: 0.97), accent: HSB(h: 0.60, s: 0.75, b: 0.90), opacity: 1.0),
        Theme(name: "Sunset", bg: HSB(h: 0.02, s: 0.60, b: 0.30), accent: HSB(h: 0.11, s: 0.75, b: 1.0), opacity: 0.97),
        Theme(name: "Ocean", bg: HSB(h: 0.55, s: 0.65, b: 0.32), accent: HSB(h: 0.50, s: 0.55, b: 1.0), opacity: 0.97),
        Theme(name: "Mint", bg: HSB(h: 0.42, s: 0.25, b: 0.93), accent: HSB(h: 0.45, s: 0.80, b: 0.60), opacity: 1.0),
        Theme(name: "Graphite", bg: HSB(h: 0.0, s: 0.0, b: 0.12), accent: HSB(h: 0.0, s: 0.0, b: 0.92), opacity: 0.95),
        Theme(name: "Rose", bg: HSB(h: 0.95, s: 0.12, b: 0.97), accent: HSB(h: 0.95, s: 0.65, b: 0.95), opacity: 1.0),
    ]
    static var `default`: Theme { presets[0] }

    var isLight: Bool { bg.luminance > 0.55 }
    var palette: Palette {
        let fg: Color = isLight ? Color(white: 0.08) : Color(white: 0.97)
        return Palette(
            bg: bg.color.opacity(opacity),
            fg: fg,
            sub: fg.opacity(0.62),
            accent: accent.color,
            accentFg: accent.luminance > 0.6 ? Color(white: 0.06) : Color.white,
            line: fg.opacity(0.12),
            hover: fg.opacity(0.09)
        )
    }
}

struct Palette {
    let bg: Color, fg: Color, sub: Color, accent: Color, accentFg: Color, line: Color, hover: Color
}

// MARK: - Talking to Amazon Music (over its local control port)

enum BridgeError: Error, LocalizedError {
    case notConnected, timeout, js(String)
    var errorDescription: String? {
        switch self {
        case .notConnected: return "Amazon Music isn't reachable"
        case .timeout: return "Amazon Music took too long to answer"
        case .js(let s): return s
        }
    }
}

actor CDP {
    private var task: URLSessionWebSocketTask?
    private var nextID = 0
    private var waiting: [Int: CheckedContinuation<Any?, Error>] = [:]
    let port: Int
    init(port: Int) { self.port = port }

    private func connect() async throws {
        if task != nil { return }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/json")!)
        req.timeoutInterval = 2
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw BridgeError.notConnected }
        let pages = arr.filter { ($0["type"] as? String) == "page" }
        guard let page = pages.first(where: { (($0["url"] as? String) ?? "").contains("amazon.com") }) ?? pages.first,
              let ws = page["webSocketDebuggerUrl"] as? String, let url = URL(string: ws) else { throw BridgeError.notConnected }
        let t = URLSession.shared.webSocketTask(with: url)
        t.maximumMessageSize = 32 * 1024 * 1024
        t.resume()
        task = t
        Task { await self.readLoop(t) }
    }

    private func readLoop(_ t: URLSessionWebSocketTask) async {
        while true {
            do {
                let msg = try await t.receive()
                var data: Data?
                switch msg {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: break
                }
                if let d = data, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let id = o["id"] as? Int {
                    complete(id, o)
                }
            } catch {
                drop(t, error)
                return
            }
        }
    }

    private func complete(_ id: Int, _ o: [String: Any]) {
        guard let c = waiting.removeValue(forKey: id) else { return }
        let result = o["result"] as? [String: Any]
        if let ex = result?["exceptionDetails"] as? [String: Any] {
            let txt = ((ex["exception"] as? [String: Any])?["description"] as? String) ?? (ex["text"] as? String) ?? "script error"
            c.resume(throwing: BridgeError.js(txt))
            return
        }
        if let e = o["error"] as? [String: Any] {
            c.resume(throwing: BridgeError.js((e["message"] as? String) ?? "error"))
            return
        }
        c.resume(returning: (result?["result"] as? [String: Any])?["value"])
    }

    private func drop(_ t: URLSessionWebSocketTask, _ e: Error) {
        if task === t { task = nil }
        let w = waiting
        waiting = [:]
        for (_, c) in w { c.resume(throwing: e) }
    }

    private func fail(_ id: Int, _ e: Error) {
        waiting.removeValue(forKey: id)?.resume(throwing: e)
    }

    func eval(_ js: String, timeout: Double = 20) async throws -> Any? {
        try await connect()
        guard let t = task else { throw BridgeError.notConnected }
        nextID += 1
        let id = nextID
        let payload: [String: Any] = ["id": id, "method": "Runtime.evaluate",
                                      "params": ["expression": js, "returnByValue": true, "awaitPromise": true]]
        let text = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Any?, Error>) in
            waiting[id] = c
            Task {
                do { try await t.send(.string(text)) } catch { self.fail(id, error) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.fail(id, BridgeError.timeout)
            }
        }
    }

    func reset() {
        if let t = task { t.cancel(with: .goingAway, reason: nil) }
        task = nil
    }
}

// The helper script placed inside the Amazon Music page. It only talks to the page's own player.
let helperVersion = 9
let helperJS = #"""
(()=>{
if(window.__mp&&window.__mp.v===9)return "ready";
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
if(!window.__mpReq){const id="__mp"+Date.now();webpackJsonp.push([[],{[id]:(m,e,r)=>{window.__mpReq=r}},[[id]]]);}
const bus=window.__mpReq("6586").a;
// Nothing in here may wait on page timers: Amazon Music freezes them while its window is hidden.
// Slow things are split into a "start" call and a "poll" call; the mini player does the waiting.
const mp={v:9,_found:{},_last:0,master:"",_pl:null};
// Optional: every song added to any playlist also goes into one "master" playlist, skipping songs already there.
if(!bus.__mpOrig){
  bus.__mpOrig=bus.execute;
  bus.execute=function(name,...args){
    const r=bus.__mpOrig.call(this,name,...args);
    try{if(name==="Library.appendTracksToPlaylist"&&window.__mp&&window.__mp.onAppend)window.__mp.onAppend(args)}catch(e){}
    return r;
  };
}
const exec=(...a)=>bus.__mpOrig.apply(bus,a);
// Amazon wants each song as a small "selection" object; catalog songs go by their Amazon id
const toSel=tr=>tr.asin?{type:"track",uniqueId:tr.asin,libraryId:"",context:"prime",isOwned:!!tr.isOwned,asin:tr.asin}
  :{type:"track",uniqueId:tr.uniqueId||tr.id,libraryId:tr.libraryId||tr.id||"",context:"library",isOwned:!!tr.isOwned};
const appendP=(pid,sels,force,view)=>new Promise(res=>{
  const to=setTimeout(()=>res("timeout"),12000);
  const done=v=>{clearTimeout(to);res(v)};
  try{exec("Library.appendTracksToPlaylist",pid,sels,!force,!force,view||(sels[0]&&sels[0].context)||"prime",()=>done("added"),()=>done("error"),()=>done("duplicate"))}
  catch(e){done("error")}
});
mp.onAppend=(args)=>{
  const pid=args[0],sels=args[1],m=mp.masterId;
  if(!m||pid===m||!sels||!sels.length)return;
  appendP(m,JSON.parse(JSON.stringify(sels)),false,args[4]);
};
const pq=()=>{if(!mp._pq||!mp._pq._id){mp._pq=bus.execute("Player.getPlayQueue")||null}return mp._pq||{}};
const items=()=>{const p=pq();return (p.list&&p.list.page1&&p.list.page1.list)||[]};
mp.refresh=()=>{mp._last=Date.now();const p=pq();if(p._id)bus.execute("Player.changePageOffset",p._id,"page1",0,3000)};
mp.state=()=>{
  try{
    const P=window.App.$store.state.player,m=P.model,s=P.settings,cp=m.currentPlayable,t=cp&&cp.track,q=pq();
    if(Date.now()-mp._last>2500)mp.refresh();
    const L=items();let h=5381;
    for(let i=0;i<L.length;i++){const u=L[i].track.uniqueId;for(let j=0;j<u.length;j++)h=((h<<5)+h+u.charCodeAt(j))|0}
    const img=document.querySelector("footer .albumArt img");
    return JSON.stringify({st:m.state,title:t?t.title:"",artist:t&&t.artist?t.artist.name:"",album:t&&t.album?t.album.name:"",
      art:img?img.src:(t&&t.album?t.album.image:""),dur:m.duration||0,pos:P.progress.currentTime||0,shuffle:!!s.shuffle,
      repeat:s.repeatSettings||"NONE",cur:q.currentPlayableIndex,n:L.length,sig:h,cont:cp&&cp.containerInfo?cp.containerInfo.containerName:""});
  }catch(e){return "NOSTATE"}
};
mp.queue=()=>{
  return JSON.stringify(items().map(x=>({u:x.track.uniqueId,t:x.track.title,a:x.track.artist?x.track.artist.name:"",
    al:x.track.album?x.track.album.name:"",d:x.track.duration||0,img:x.track.album?(x.track.album.image||""):"",asin:x.track.asin||""})));
};
mp.click=q=>{const b=document.querySelector("[data-qaid="+q+"]");if(b){b.click();return true}return false};
mp.playIndex=i=>{bus.execute("Player.changePlayingTrack",i);return true};
mp.moveAfter=(uids,anchor)=>{bus.execute("Player.reorderPlayables",uids,anchor);return true};
mp.remove=uids=>{bus.execute("Player.removeFromPlayQueue",uids);return true};
mp.searchStart=(kw)=>{
  if(mp._sv){try{bus.execute("Library.release",mp._sv._id)}catch(e){}}
  mp._sv=bus.execute("Library.getSearchResults",{keyword:kw,allowCorrection:true});mp._svAt=Date.now();
  return "started";
};
mp.searchPoll=()=>{
  const v=mp._sv;if(!v)return "[]";
  const sec=v.prime&&v.prime.sections&&v.prime.sections.find(s=>s.type==="track");
  if(!(sec&&sec.items&&sec.items.length)&&Date.now()-mp._svAt<8000)return "WAIT";
  const out=[];
  if(sec&&sec.items){for(const it of sec.items.slice(0,20)){
    const c=JSON.parse(JSON.stringify(it));mp._found[c.asin]=c;
    out.push({asin:c.asin,t:c.title,a:c.artist?c.artist.name:"",d:+c.duration||0,img:c.image||(c.album&&c.album.image)||"",
      al:c.album?(c.album.name||c.album.title||""):"",rd:+c.originalReleaseDate||0});}}
  try{bus.execute("Library.release",v._id)}catch(e){}
  mp._sv=null;
  return JSON.stringify(out);
};
mp.insertStart=(asin)=>{
  const tr=mp._found[asin];if(!tr)return "gone";
  mp._before=new Set(items().map(x=>x.track.uniqueId));mp._insAt=Date.now();
  const cur=pq().currentPlayableIndex,ci=JSON.parse(JSON.stringify(items()[cur].containerInfo));
  bus.execute("Player.insertNext",[tr],ci,{});
  return "started";
};
mp.insertPoll=()=>{
  mp.refresh();
  const L=items(),idx=L.findIndex(x=>!mp._before.has(x.track.uniqueId));
  if(idx>=0)return JSON.stringify({u:L[idx].track.uniqueId,idx});
  return Date.now()-mp._insAt<9000?"WAIT":JSON.stringify({err:"timeout"});
};
const findMaster=()=>{
  if(!mp.master||!mp._pl)return;
  const mm=mp._pl.find(p=>(p.t||"").toLowerCase().replace(/[^a-z0-9]/g,"")===mp.master);mp.masterId=mm?mm.id:null;
};
mp.playlistsPoll=(fresh)=>{
  if(fresh||!mp._plv){if(mp._plv){try{bus.execute("Library.release",mp._plv._id)}catch(e){}}mp._plv=bus.execute("Library.getPlaylists");mp._plvAt=Date.now()}
  const a=mp._plv,u=a&&a.playlists&&a.playlists.user;
  if(!u)return Date.now()-mp._plvAt<8000?"WAIT":"[]";
  mp._pl=u.map(p=>({id:p.id,t:p.title||"",n:p.totalTrackCount||0,img:typeof p.image==="string"?p.image:""}));
  try{bus.execute("Library.release",a._id)}catch(e){}
  mp._plv=null;findMaster();
  return JSON.stringify(mp._pl);
};
mp.addToPlaylist=async(pid,kind,key,force)=>{
  let tr=null;
  if(kind==="current"){const cp=App.$store.state.player.model.currentPlayable;tr=cp&&cp.track}
  else if(kind==="queue"){const it=items().find(x=>x.track.uniqueId===key);tr=it&&it.track}
  else{tr=mp._found[key]}
  if(!tr)return JSON.stringify({t:"missing",m:"none"});
  findMaster();
  const sel=toSel(JSON.parse(JSON.stringify(tr)));
  const t=await appendP(pid,[sel],force);
  let m="none";
  if(mp.masterId&&mp.masterId!==pid)m=await appendP(mp.masterId,[sel],false);
  return JSON.stringify({t,m});
};
mp.setMaster=(name)=>{
  mp.master=(name||"").toLowerCase().replace(/[^a-z0-9]/g,"");mp.masterId=null;findMaster();
  return mp.masterId||"";
};
window.__mp=mp;mp.refresh();
return "ready";
})()
"""#

// MARK: - Data

struct QItem: Identifiable, Equatable {
    let id: String
    let title: String, artist: String, album: String
    let duration: Int
    let art: String
    let asin: String
}

struct NowPlaying: Equatable {
    var title = "", artist = "", album = "", art = ""
    var playing = false
    var pos: Double = 0, dur: Double = 0
    var shuffle = false
    var repeatMode = "NONE"
    var container = ""
}

struct PlaylistInfo: Identifiable, Equatable {
    let id: String
    let title: String
    let count: Int
    let image: String
}

struct Suggestion: Identifiable, Equatable {
    let id: String   // song id in Amazon's catalog
    let title: String, artist: String, art: String, reason: String
    let duration: Int
}

enum ConnState: Equatable {
    case starting
    case needsRestart           // Amazon Music is open but without the control port
    case restarting
    case waiting                // Amazon Music is launching
    case connected
}

// MARK: - Model

@MainActor
final class PlayerModel: ObservableObject {
    @Published var conn: ConnState = .starting
    @Published var now = NowPlaying()
    @Published var queue: [QItem] = []
    @Published var currentIndex = 0
    @Published var lineup: [String: Int] = [:]      // song id -> its spot in "your line-up" (1, 2, 3...)
    @Published var pinned: Bool { didSet { UserDefaults.standard.set(pinned, forKey: "pinned") } }
    @Published var showList: Bool { didSet { UserDefaults.standard.set(showList, forKey: "showList") } }
    @Published var theme: Theme { didSet { saveTheme() } }
    @Published var showDiscover = false
    @Published var suggestions: [Suggestion] = []
    @Published var discovering = false
    @Published var discoverNote = ""
    @Published var toast = ""
    @Published var playlists: [PlaylistInfo] = []
    /// Playlist that every added song also goes into ("" = off).
    @Published var masterPlaylist: String {
        didSet { UserDefaults.standard.set(masterPlaylist, forKey: "masterPlaylist"); Task { await pushMaster() } }
    }
    static let tipURL = URL(string: "https://venmo.com/u/LandonHopkins1")!
    private var recentPlaylists: [String] = UserDefaults.standard.stringArray(forKey: "recentPlaylists") ?? []
    private var playlistsDue = Date.distantPast

    private let cdp = CDP(port: 9333)
    // songs the user added, in the order added (remembered, with each song's id, in case the app reopens)
    private var userQueued: [String] = [] { didSet { UserDefaults.standard.set(userQueued, forKey: "userQueued") } }
    private var queuedAsin: [String: String] = [:] { didSet { UserDefaults.standard.set(queuedAsin, forKey: "queuedAsin") } }
    var wantsRoomForList: ((Bool) -> Void)?
    private var lastSig = 0
    private var lastCur = -1
    private var lastTitle = ""
    private var launchedAmazon = false
    private var waitingSince = Date()
    private var amazonSeenAt: Date?
    private var amazonPID: pid_t = 0
    private var loop: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    // discovery memory
    private var shownIDs = Set<String>()
    private var usedArtists = Set<String>()
    private var discoverContainer = ""

    init() {
        let d = UserDefaults.standard
        pinned = d.object(forKey: "pinned") as? Bool ?? true
        showList = d.object(forKey: "showList") as? Bool ?? true
        userQueued = d.stringArray(forKey: "userQueued") ?? []
        masterPlaylist = d.string(forKey: "masterPlaylist") ?? ""
        queuedAsin = (d.dictionary(forKey: "queuedAsin") as? [String: String]) ?? [:]
        if let data = d.data(forKey: "theme"), let t = try? JSONDecoder().decode(Theme.self, from: data) { theme = t } else { theme = .default }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }
    }

    private func saveTheme() {
        if let data = try? JSONEncoder().encode(theme) { UserDefaults.standard.set(data, forKey: "theme") }
    }

    // MARK: connection

    private func str(_ js: String, timeout: Double = 20) async throws -> String {
        let v = try await cdp.eval(js, timeout: timeout)
        if let s = v as? String { return s }
        if let b = v as? Bool { return b ? "true" : "false" }
        return ""
    }

    private var amazonURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.amazon.music")
    }
    private func amazonRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.amazon.music").isEmpty
    }

    func launchAmazon() {
        guard let url = amazonURL else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.arguments = ["--remote-debugging-port=9333", "--disable-background-timer-throttling",
                         "--disable-renderer-backgrounding", "--disable-backgrounding-occluded-windows"]
        cfg.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
    }

    /// Closes Amazon Music and opens it again with the control port switched on.
    func restartAmazon() {
        guard conn != .restarting else { return }
        conn = .restarting
        Task {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.amazon.music") { app.terminate() }
            var waited = 0
            while amazonRunning() && waited < 40 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                waited += 1
            }
            if amazonRunning() { conn = .needsRestart; flash("Please quit Amazon Music, then press Connect"); return }
            await cdp.reset()
            launchAmazon()
            launchedAmazon = true
            waitingSince = Date()
            conn = .waiting
        }
    }

    /// Amazon Music sets itself up during its first seconds; connecting during that time makes it hang on its splash screen.
    private func amazonSettled() -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.amazon.music").first else { return false }
        if amazonSeenAt == nil || amazonPID != app.processIdentifier {
            amazonPID = app.processIdentifier
            amazonSeenAt = app.launchDate ?? Date()
        }
        return Date().timeIntervalSince(amazonSeenAt!) > 15
    }

    private func tick() async {
        if conn != .connected && conn != .restarting && amazonRunning() && !amazonSettled() {
            if conn != .waiting { waitingSince = Date() }
            conn = .waiting
            return
        }
        do {
            // only step in once Amazon Music has fully loaded its player
            var raw = try await str("(window.__mp&&window.__mp.v===\(helperVersion))?window.__mp.state():" +
                                    "((window.App&&App.$store&&App.$store.state.player&&App.$store.state.player.model&&document.querySelector('footer'))?'NOINSTALL':'NOTREADY')", timeout: 6)
            if raw == "NOTREADY" { conn = .waiting; return }
            if raw == "NOINSTALL" {
                _ = try await str(helperJS, timeout: 10)
                await pushMaster()
                raw = try await str("window.__mp.state()", timeout: 6)
            }
            if raw == "NOSTATE" || raw.isEmpty { if conn != .connected { conn = .waiting }; return }
            apply(raw)
            conn = .connected
            if Date() > playlistsDue {
                playlistsDue = Date().addingTimeInterval(120)
                Task { await loadPlaylists() }
            }
        } catch {
            await cdp.reset()
            if conn == .restarting { return }
            if amazonRunning() {
                // still starting up after we launched it? give it time; otherwise it was opened without the control port
                if conn == .waiting, Date().timeIntervalSince(waitingSince) < 45 { return }
                conn = .needsRestart
            } else {
                // Amazon Music isn't open: open it (with the control port) for the user
                if !launchedAmazon || Date().timeIntervalSince(waitingSince) > 45 {
                    launchedAmazon = true
                    launchAmazon()
                    waitingSince = Date()
                }
                conn = .waiting
            }
        }
    }

    private func apply(_ raw: String) {
        guard let data = raw.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var n = NowPlaying()
        n.title = o["title"] as? String ?? ""
        n.artist = o["artist"] as? String ?? ""
        n.album = o["album"] as? String ?? ""
        n.art = o["art"] as? String ?? ""
        n.playing = (o["st"] as? String) == "PLAYING"
        n.pos = ((o["pos"] as? Double) ?? 0) / 1000
        n.dur = ((o["dur"] as? Double) ?? 0) / 1000
        n.shuffle = o["shuffle"] as? Bool ?? false
        n.repeatMode = o["repeat"] as? String ?? "NONE"
        n.container = o["cont"] as? String ?? ""
        if n != now { now = n }
        let cur = (o["cur"] as? Int) ?? 0
        let sig = (o["sig"] as? Int) ?? 0
        if cur != currentIndex { currentIndex = cur; recomputeLineup() }
        if sig != lastSig || cur != lastCur || n.title != lastTitle || queue.isEmpty {
            lastSig = sig; lastCur = cur; lastTitle = n.title
            Task { await fetchQueue() }
        }
    }

    /// Asks the page again every 120 ms until it has an answer (the page can't wait on its own timers while hidden).
    private func poll(_ js: String, every ms: UInt64 = 120, upTo seconds: Double = 10) async -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            guard let r = try? await str(js, timeout: 6) else { return nil }
            if r != "WAIT" { return r }
            try? await Task.sleep(nanoseconds: ms * 1_000_000)
        }
        return nil
    }

    func fetchQueue() async {
        _ = try? await cdp.eval("window.__mp.refresh()", timeout: 6)
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard let raw = try? await str("window.__mp.queue()", timeout: 10),
              let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        let items = arr.map {
            QItem(id: $0["u"] as? String ?? UUID().uuidString, title: $0["t"] as? String ?? "", artist: $0["a"] as? String ?? "",
                  album: $0["al"] as? String ?? "", duration: ($0["d"] as? Int) ?? Int(($0["d"] as? Double) ?? 0),
                  art: $0["img"] as? String ?? "", asin: $0["asin"] as? String ?? "")
        }
        if items != queue { queue = items }
        recomputeLineup()
    }

    // MARK: your line-up (songs you added, in the order you added them)

    private func lineupRun() -> [String] {
        var run: [String] = []
        var i = currentIndex + 1
        while i < queue.count, userQueued.contains(queue[i].id) {
            run.append(queue[i].id)
            i += 1
        }
        return run
    }

    private func recomputeLineup() {
        let positions = Dictionary(uniqueKeysWithValues: queue.enumerated().map { ($0.element.id, $0.offset) })
        guard !queue.isEmpty else { return }
        let kept = userQueued.filter { id in
            guard let pos = positions[id], pos > currentIndex else { return false }
            if let a = queuedAsin[id], !a.isEmpty, a != queue[pos].asin { return false }
            return true
        }
        if kept != userQueued {
            userQueued = kept
            queuedAsin = queuedAsin.filter { kept.contains($0.key) }
        }
        var map: [String: Int] = [:]
        for (i, id) in lineupRun().enumerated() { map[id] = i + 1 }
        if map != lineup { lineup = map }
    }

    // MARK: controls

    private func run(_ js: String) {
        Task { _ = try? await cdp.eval(js, timeout: 10) }
    }
    private func press(_ qaid: String) { run("window.__mp.click('\(qaid)')") }

    func playPause() { now.playing.toggle(); press("playPause") }
    func next() { press("next") }
    func previous() { press("previous") }
    func toggleShuffle() { now.shuffle.toggle(); press("shuffle") }
    func toggleRepeat() { press("repeat") }

    func play(_ item: QItem) {
        guard let i = queue.firstIndex(of: item) else { return }
        run("window.__mp.playIndex(\(i))")
    }

    private func move(_ item: QItem, after anchor: Int) async {
        let js = "window.__mp.moveAfter(['\(item.id)'],\(anchor))"
        _ = try? await cdp.eval(js, timeout: 10)
        try? await Task.sleep(nanoseconds: 500_000_000)
        await fetchQueue()
    }

    /// "Next": plays right after the current song (jumps ahead of anything you added earlier).
    func playNext(_ item: QItem) {
        guard let i = queue.firstIndex(of: item), i != currentIndex else { return }
        remember(item.id, item.asin)
        Task { await move(item, after: currentIndex); flash("Playing next: \(item.title)") }
    }

    /// "Add to queue": goes behind anything you already added (1st plays next, 2nd after it, and so on).
    func addToQueue(_ item: QItem) {
        guard let i = queue.firstIndex(of: item), i != currentIndex else { return }
        let run = lineupRun()
        if run.last == item.id { return }
        // land right behind the last song you already added (or right after the current song if none)
        let anchor = run.last.flatMap { last in queue.firstIndex { $0.id == last } } ?? currentIndex
        remember(item.id, item.asin)
        Task {
            await move(item, after: min(anchor, queue.count - 1))
            let spot = lineup[item.id] ?? (run.count + 1)
            flash("Added to queue (#\(spot)): \(item.title)")
        }
    }

    private func remember(_ uid: String, _ asin: String) {
        userQueued.removeAll { $0 == uid }
        userQueued.append(uid)
        queuedAsin[uid] = asin
    }

    func toggleList() {
        if showDiscover { showDiscover = false; showList = true } else { showList.toggle() }
        wantsRoomForList?(showList)
    }

    func toggleDiscover() {
        if showDiscover { showDiscover = false; return }
        showList = true
        wantsRoomForList?(true)
        if suggestions.isEmpty { findNewMusic() } else { showDiscover = true }
    }

    func removeFromQueue(_ item: QItem) {
        userQueued.removeAll { $0 == item.id }
        run("window.__mp.remove(['\(item.id)'])")
        Task { try? await Task.sleep(nanoseconds: 600_000_000); await fetchQueue() }
    }

    // MARK: add to playlist

    enum AddTarget { case current, queueItem(String), suggestion(String) }

    /// Your playlists, the ones you used most recently first.
    var sortedPlaylists: [PlaylistInfo] {
        let rank = Dictionary(uniqueKeysWithValues: recentPlaylists.enumerated().map { ($0.element, $0.offset) })
        return playlists.sorted {
            let a = rank[$0.id] ?? Int.max, b = rank[$1.id] ?? Int.max
            return a != b ? a < b : $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }
    func isRecent(_ p: PlaylistInfo) -> Bool { recentPlaylists.prefix(3).contains(p.id) }

    func pushMaster() async {
        if !masterPlaylist.isEmpty { await loadPlaylists() }
        let esc = masterPlaylist.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        _ = try? await cdp.eval("window.__mp&&window.__mp.setMaster('\(esc)')", timeout: 10)
    }

    func openTip() { NSWorkspace.shared.open(Self.tipURL) }

    func loadPlaylists() async {
        _ = try? await str("window.__mp.playlistsPoll(true)", timeout: 6)
        guard let raw = await poll("window.__mp.playlistsPoll(false)", upTo: 10),
              let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !arr.isEmpty else { return }
        let list = arr.map { PlaylistInfo(id: $0["id"] as? String ?? "", title: $0["t"] as? String ?? "",
                                          count: ($0["n"] as? Int) ?? 0, image: $0["img"] as? String ?? "") }
        if list != playlists { playlists = list }
    }

    func addToPlaylist(_ target: AddTarget, _ pl: PlaylistInfo, force: Bool = false) {
        let (kind, key): (String, String)
        switch target {
        case .current: (kind, key) = ("current", "")
        case .queueItem(let uid): (kind, key) = ("queue", uid)
        case .suggestion(let asin): (kind, key) = ("found", asin)
        }
        recentPlaylists.removeAll { $0 == pl.id }
        recentPlaylists.insert(pl.id, at: 0)
        recentPlaylists = Array(recentPlaylists.prefix(8))
        UserDefaults.standard.set(recentPlaylists, forKey: "recentPlaylists")
        let pid = pl.id.replacingOccurrences(of: "'", with: "\\'")
        let k = key.replacingOccurrences(of: "'", with: "\\'")
        Task {
            let raw = (try? await str("window.__mp.addToPlaylist('\(pid)','\(kind)','\(k)',\(force))", timeout: 30)) ?? ""
            let o = (raw.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
            let t = o["t"] ?? "error", master = o["m"] ?? "none"
            let name = "“\(pl.title)”"
            let mName = masterPlaylist
            switch (t, master) {
            case ("added", "added"): flash("Added to \(name) + \(mName)")
            case ("added", "duplicate"): flash("Added to \(name) (already in \(mName))")
            case ("added", _): flash("Added to \(name)")
            case ("duplicate", "added"): flash("Already in \(name) — added to \(mName)")
            case ("duplicate", "duplicate"): flash("Already in \(name) and \(mName)")
            case ("duplicate", _): flash("Already in \(name)")
            default: flash("Couldn't add to \(name) — try again")
            }
            if t == "added" || master == "added" {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await loadPlaylists()
            }
        }
    }

    func flash(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { toast = "" }
        }
    }

    // MARK: find new music

    private func norm(_ s: String) -> String { normName(s) }
    private func artistParts(_ name: String) -> [String] { splitArtists(name) }

    struct Found { let asin: String; let title: String; let artist: String; let dur: Int; let img: String; let album: String; let year: Int? }

    private func searchSongs(_ keyword: String) async -> [Found] {
        let esc = keyword.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        _ = try? await str("window.__mp.searchStart('\(esc)')", timeout: 6)
        guard let raw = await poll("window.__mp.searchPoll()", upTo: 10),
              let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.map {
            let rd = ($0["rd"] as? Double) ?? Double(($0["rd"] as? Int) ?? 0)
            let year = rd > 0 ? Calendar.current.component(.year, from: Date(timeIntervalSince1970: rd)) : nil
            return Found(asin: $0["asin"] as? String ?? "", title: $0["t"] as? String ?? "", artist: $0["a"] as? String ?? "",
                         dur: ($0["d"] as? Int) ?? Int(($0["d"] as? Double) ?? 0), img: $0["img"] as? String ?? "",
                         album: $0["al"] as? String ?? "", year: year)
        }
    }

    func findNewMusic() {
        guard !discovering else { return }
        showDiscover = true
        showList = true
        wantsRoomForList?(true)
        discovering = true
        discoverNote = "Looking at your playlist…"
        if discoverContainer != now.container { shownIDs = []; usedArtists = []; discoverContainer = now.container }
        suggestions = []
        Task {
            await runDiscovery()
            discovering = false
            if suggestions.isEmpty { discoverNote = "Couldn't find anything new right now. Try again in a moment." }
        }
    }

    private enum Step { case similar(DiscoveryKB.Candidate), deep(String) }

    private func runDiscovery() async {
        // 1. what the playlist is made of
        var profile: [String: Int] = [:]          // artist -> number of songs in this playlist
        var display: [String: String] = [:]
        var songsBy: [String: [String]] = [:]
        var albumsBy: [String: Set<String>] = [:]
        for q in queue {
            for p in artistParts(q.artist) {
                let k = norm(p)
                if k.isEmpty { continue }
                profile[k, default: 0] += 1
                display[k] = display[k] ?? p
                songsBy[k, default: []].append(cleanTitle(q.title))
                albumsBy[k, default: []].insert(norm(q.album))
            }
        }
        let inQueueAsins = Set(queue.map { $0.asin })
        let inQueueKeys = Set(queue.map { norm($0.title) + "|" + norm(artistParts($0.artist).last ?? $0.artist) } +
                              queue.map { norm($0.title) + "|" + norm($0.artist) })
        let queueArtists = Set(profile.keys)
        var inQueuePairs = Set<String>()
        for q in queue { for part in artistParts(q.artist) { inQueuePairs.insert(norm(q.title) + "|" + norm(part)) } }

        // 2. pick related artists (weighted toward the strongest matches) plus a couple of artists you already play
        var plan: [Step] = []
        var pool = DiscoveryKB.similar(profile: profile, exclude: queueArtists.union(usedArtists))
        var picked = 0
        while picked < 5, !pool.isEmpty {
            let total = pool.prefix(24).reduce(0.0) { $0 + $1.weight }
            var r = Double.random(in: 0..<max(total, 0.0001))
            var idx = 0
            for (i, c) in pool.prefix(24).enumerated() { r -= c.weight; if r <= 0 { idx = i; break } }
            plan.append(.similar(pool.remove(at: idx)))
            picked += 1
        }
        let topArtists = profile.sorted { $0.value > $1.value }.map { $0.key }.filter { $0 != norm("Various Artists") }
        var deepPool = Array(topArtists.prefix(10)).shuffled()
        let deepCount = picked == 0 ? 6 : 2
        for _ in 0..<deepCount { if let k = deepPool.popLast() { plan.append(.deep(k)) } }
        if plan.isEmpty { discoverNote = "Play something first, then I can look for more like it."; return }
        discoverNote = picked == 0 ? "More songs from artists in this playlist" : "Picked from what's in this playlist"

        // 3. look each one up, take a song that isn't already here, and say why it fits
        var writer = ReasonWriter(display: display, songsBy: songsBy, albumsBy: albumsBy, profile: profile)
        let bad = ["karaoke", "tribute", "instrumental", "lullaby", "8-bit", "cover version"]
        for step in plan {
            let name: String
            switch step {
            case .similar(let c): name = c.name
            case .deep(let k): name = display[k] ?? k
            }
            let want = norm(name)
            let found = await searchSongs(name)
            let fresh = found.filter { f in
                let a = norm(f.artist)
                let parts = artistParts(f.artist).map(norm)
                guard !a.isEmpty, parts.contains(want) else { return false }
                if parts.contains(where: { inQueuePairs.contains(norm(f.title) + "|" + $0) }) { return false }
                if inQueueAsins.contains(f.asin) || shownIDs.contains(f.asin) { return false }
                let t = f.title.lowercased()
                if bad.contains(where: { t.contains($0) }) { return false }
                return !inQueueKeys.contains(norm(f.title) + "|" + a) && !inQueueKeys.contains(norm(f.title) + "|" + want)
            }
            guard let f = fresh.prefix(4).randomElement() else { continue }
            let reason: String
            switch step {
            case .similar(let c): reason = writer.similar(c, found: f)
            case .deep(let k): reason = writer.deep(k, found: f)
            }
            shownIDs.insert(f.asin)
            usedArtists.insert(want)
            withAnimation { suggestions.append(Suggestion(id: f.asin, title: f.title, artist: f.artist, art: f.img, reason: reason, duration: f.dur)) }
        }
    }

    enum AddMode { case play, next, queue }

    func use(_ s: Suggestion, _ mode: AddMode) {
        Task {
            let runBefore = lineupRun()
            let esc = s.id.replacingOccurrences(of: "'", with: "\\'")
            guard (try? await str("window.__mp.insertStart('\(esc)')", timeout: 6)) == "started",
                  let raw = await poll("window.__mp.insertPoll()", every: 200, upTo: 11),
                  let data = raw.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let uid = o["u"] as? String, let idx = o["idx"] as? Int else {
                flash("Couldn't add that one — try again")
                return
            }
            withAnimation { suggestions.removeAll { $0.id == s.id } }   // used — take it off the list
            switch mode {
            case .play:
                _ = try? await cdp.eval("window.__mp.playIndex(\(idx))", timeout: 10)
                flash("Playing: \(s.title)")
            case .next:
                remember(uid, s.id)
                flash("Playing next: \(s.title)")
            case .queue:
                remember(uid, s.id)
                if let last = runBefore.last {
                    await fetchQueue()
                    if let a = queue.firstIndex(where: { $0.id == last }) {
                        _ = try? await cdp.eval("window.__mp.moveAfter(['\(uid)'],\(a))", timeout: 10)
                    }
                }
                flash("Added to queue (#\(runBefore.count + 1)): \(s.title)")
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            await fetchQueue()
        }
    }
}

// MARK: - Knowledge for "find new music"

func normName(_ s: String) -> String {
    var t = s.lowercased()
    for pair in [("\\[[^\\]]*\\]", ""), ("\\([^)]*\\)", ""), ("[^a-z0-9]+", "")] {
        t = t.replacingOccurrences(of: pair.0, with: pair.1, options: .regularExpression)
    }
    return t
}

func splitArtists(_ name: String) -> [String] {
    var parts = [name]
    var s = name
    for sep in [" feat. ", " ft. ", " & ", ", ", " x ", " and "] { s = s.replacingOccurrences(of: sep, with: "|") }
    let split = s.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }
    if split.count > 1 { parts += split }
    return parts
}

func cleanTitle(_ t: String) -> String {
    t.replacingOccurrences(of: "\\s*\\[(Explicit|Clean)\\]", with: "", options: [.regularExpression, .caseInsensitive])
        .trimmingCharacters(in: .whitespaces)
}

func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

/// Writes a short, specific "why you'd like it" line, tied to real songs and artists in the playlist.
struct ReasonWriter {
    let display: [String: String]
    let songsBy: [String: [String]]
    let albumsBy: [String: Set<String>]
    let profile: [String: Int]
    var usedRefs = Set<String>()
    var usedTemplates = Set<Int>()
    var usedSongs = Set<String>()

    private mutating func song(of k: String) -> String? {
        let all = songsBy[k] ?? []
        guard let s = all.filter({ !usedSongs.contains($0) }).randomElement() ?? all.randomElement() else { return nil }
        usedSongs.insert(s)
        return s
    }

    private mutating func choose(_ options: [(Int, String)]) -> String {
        let fresh = options.filter { !usedTemplates.contains($0.0) }
        let pick = fresh.randomElement() ?? options.randomElement()!
        usedTemplates.insert(pick.0)
        return pick.1
    }

    mutating func similar(_ c: DiscoveryKB.Candidate, found f: PlayerModel.Found) -> String {
        let vibe = cap(DiscoveryKB.describe(c))
        // a feature with someone already in the playlist says it best
        for part in splitArtists(f.artist) {
            let k = normName(part)
            if k != normName(c.name), profile[k] != nil { return "\(vibe) · with \(display[k] ?? part)" }
        }
        let refs = c.matched
        guard let a = refs.first(where: { !usedRefs.contains($0) }) ?? refs.first else { return vibe }
        usedRefs.insert(a)
        let A = display[a] ?? a
        var options: [(Int, String)] = [(1, "\(vibe) · like \(A)"), (2, "\(vibe) · for \(A) fans")]
        if let b = refs.first(where: { $0 != a && !usedRefs.contains($0) }) ?? refs.first(where: { $0 != a }) {
            options.append((3, "Like \(A) + \(display[b] ?? b)"))
        }
        if let tune = song(of: a), tune.count <= 24 { options.append((4, "\(vibe) · goes with “\(tune)”")) }
        return choose(options)
    }

    mutating func deep(_ k: String, found f: PlayerModel.Found) -> String {
        let A = display[k] ?? k
        let album = cleanTitle(f.album)
        let isSingle = album.isEmpty || normName(album) == normName(f.title)
        let thisYear = Calendar.current.component(.year, from: Date())
        var options: [(Int, String)] = [(10, "More \(A)")]
        if let y = f.year {
            options.append((11, "More \(A) · \(y)"))
            if y >= thisYear - 1 { options.append((12, "Newer \(A) · \(y)")) }
        }
        if !isSingle, album.count <= 26 { options.append((13, "More \(A) · from “\(album)”")) }
        return choose(options)
    }
}

enum DiscoveryKB {
    struct Candidate { let name: String; let weight: Double; let cluster: Int; let matched: [String] }
    struct Cluster { let vibes: [String]; let artists: [String] }

    static let clusters: [Cluster] = [
        Cluster(vibes: ["glitchy hyperpop", "chaotic internet pop", "sugar-rush hyperpop"],
                artists: ["100 gecs", "Glaive", "Ericdoa", "Underscores", "2hollis", "midwxst", "brakence", "osquinn", "Jane Remover", "Dylan Brady", "Laura Les",
                          "Charli XCX", "SOPHIE", "A. G. Cook", "Food House", "fraxiom", "Machine Girl", "Dorian Electra", "Alice Longyu Gao", "Ninajirachi",
                          "Danny L Harle", "Hannah Diamond", "Rina Sawayama", "Slayyyter", "Kero Kero Bonito", "Cmten", "Quadeca", "Lightris", "Raegun",
                          "Pingmas", "poptropicaslutz!", "ovrwrld", "CThruRio", "Bryce Bishop", "d0llywood1", "Porter Robinson", "Mura Masa", "Poppy",
                          "Frost Children", "ovine hall", "Cybertrash", "kurtains", "pluko", "Aldn", "Kmoe"]),
        Cluster(vibes: ["emo rap", "moody melodic rap", "sad rap"],
                artists: ["Lil Peep", "Juice WRLD", "iann dior", "Trippie Redd", "nothing,nowhere.", "Yung Lean", "Bladee", "Ecco2k", "Lil Tracy", "Ghostemane",
                          "$uicideboy$", "brakence", "Ericdoa", "midwxst", "Glaive", "Ski Mask the Slump God", "Lil Uzi Vert", "XXXTENTACION", "The Kid LAROI",
                          "Jaden", "Powfu", "Yeat", "Destroy Lonely", "Ken Carson", "2hollis", "Osquinn"]),
        Cluster(vibes: ["experimental rap", "weird, inventive rap", "left-field rap"],
                artists: ["Quadeca", "JPEGMAFIA", "Danny Brown", "Injury Reserve", "clipping.", "Earl Sweatshirt", "Denzel Curry", "Tyler, The Creator", "Brockhampton",
                          "Black Midi", "Yves Tumor", "Kevin Abstract", "Playboi Carti", "Ericdoa", "Underscores", "Mac Miller", "Vince Staples", "Kid Cudi", "Joji"]),
        Cluster(vibes: ["bedroom pop", "soft indie pop", "lo-fi guitar pop"],
                artists: ["girl in red", "Beabadoobee", "Clairo", "mxmtoon", "Cavetown", "Soccer Mommy", "Wallows", "Conan Gray", "Dodie", "Gracie Abrams", "Laufey",
                          "Rex Orange County", "Dayglow", "Current Joys", "Cuco", "Men I Trust", "Boy Pablo", "Lovejoy", "Hippo Campus", "Surf Curse", "Alvvays",
                          "Japanese Breakfast", "Mitski", "Phoebe Bridgers", "Lizzy McAlpine", "Olivia Rodrigo"]),
        Cluster(vibes: ["pop-punk", "loud emo", "shout-along rock"],
                artists: ["Paramore", "Fall Out Boy", "My Chemical Romance", "Panic! At The Disco", "Green Day", "blink-182", "Sum 41", "All Time Low", "Simple Plan",
                          "Mayday Parade", "The Wonder Years", "Neck Deep", "State Champs", "Jimmy Eat World", "Taking Back Sunday", "Yellowcard", "Good Charlotte",
                          "Willow", "Machine Gun Kelly", "Waterparks", "Pierce The Veil", "Sleeping With Sirens", "5 Seconds of Summer", "Tigers Jaw", "Origami Angel",
                          "Knuckle Puck", "Real Friends", "Hot Mulligan", "twenty one pilots"]),
        Cluster(vibes: ["big theatrical pop", "catchy alt-pop", "stomp-clap pop"],
                artists: ["AJR", "twenty one pilots", "Imagine Dragons", "fun.", "WALK THE MOON", "Oh Wonder", "MisterWives", "Foster the People", "Capital Cities",
                          "Bastille", "American Authors", "Magic Man", "Kodaline", "Coldplay", "lovelytheband", "Joywave", "Judah & the Lion", "CHVRCHES",
                          "Glass Animals", "Young the Giant", "The Neighbourhood", "Cage The Elephant", "OneRepublic", "Panic! At The Disco", "X Ambassadors",
                          "Hellogoodbye", "Barns Courtney", "Tom Odell", "Mother Mother", "Fitz and The Tantrums", "Jon Bellion", "Cavetown"]),
        Cluster(vibes: ["indie rock", "alt rock", "guitar rock"],
                artists: ["Arctic Monkeys", "The Strokes", "Tame Impala", "Cage The Elephant", "Foals", "The Killers", "Muse", "Radiohead", "Pixies",
                          "Queens of the Stone Age", "Royal Blood", "Spoon", "The Black Keys", "Vampire Weekend", "Two Door Cinema Club", "Phoenix", "MGMT",
                          "Franz Ferdinand", "Interpol", "Bloc Party", "Kings of Leon", "The 1975", "Wallows", "Mother Mother", "Bastille", "Foster the People"]),
        Cluster(vibes: ["rap", "hard-hitting rap", "big hip-hop"],
                artists: ["Kendrick Lamar", "J. Cole", "Drake", "Travis Scott", "Tyler, The Creator", "Kanye West", "Lil Uzi Vert", "Playboi Carti", "Future", "21 Savage",
                          "Metro Boomin", "A$AP Rocky", "JID", "Denzel Curry", "Joey Bada$$", "Mac Miller", "Logic", "Post Malone", "Juice WRLD", "Lil Baby", "Gunna",
                          "Don Toliver", "Kid Cudi", "Childish Gambino", "Eminem", "Cordae", "Isaiah Rashad", "Baby Keem"]),
        Cluster(vibes: ["pop", "catchy pop", "big glossy pop"],
                artists: ["Dua Lipa", "Olivia Rodrigo", "Taylor Swift", "Billie Eilish", "Ariana Grande", "Sabrina Carpenter", "Chappell Roan", "Doja Cat", "Lizzo",
                          "Harry Styles", "The Weeknd", "Lorde", "Tate McRae", "Ava Max", "Gracie Abrams", "Reneé Rapp", "Troye Sivan", "Lady Gaga", "Charli XCX",
                          "Kesha", "Carly Rae Jepsen", "Maisie Peters", "Halsey", "Melanie Martinez", "Lana Del Rey", "Katy Perry", "Selena Gomez", "Demi Lovato",
                          "Bruno Mars", "Justin Bieber", "Shawn Mendes", "Camila Cabello", "Lauv", "Conan Gray", "Benson Boone", "Gigi Perez"]),
        Cluster(vibes: ["electronic", "dance music", "big-drop electronic"],
                artists: ["Porter Robinson", "Madeon", "ODESZA", "Flume", "Skrillex", "KAYTRANADA", "Jai Wolf", "San Holo", "ILLENIUM", "Said the Sky", "Seven Lions",
                          "REZZ", "Zedd", "Marshmello", "Alison Wonderland", "Kavinsky", "The Chainsmokers", "Calvin Harris", "Disclosure", "Fred again..", "Four Tet",
                          "Jamie xx", "Caribou", "Bonobo", "Daft Punk", "deadmau5", "Justice", "Chromeo", "Anamanaguchi", "Gesaffelstein", "Ninajirachi", "Mura Masa",
                          "Klangkuenstler", "Ski Aggu", "Boys Noize"]),
        Cluster(vibes: ["chill music", "mellow vibes", "late-night chill"],
                artists: ["Joji", "keshi", "Rich Brian", "Brian Eno", "Tycho", "Bonobo", "Nils Frahm", "Ólafur Arnalds", "Max Richter", "Explosions in the Sky",
                          "Hammock", "Sleeping At Last", "Novo Amor", "Bon Iver", "Jinsang", "Idealism", "Nujabes", "Tomppabeats", "Mac Miller", "Khruangbin",
                          "Men I Trust", "Daniel Caesar", "Frank Ocean", "Alina Baraz", "Cigarettes After Sex", "Beach House", "Mazzy Star", "Slowdive", "Washed Out"]),
        Cluster(vibes: ["indie folk", "rainy-day folk", "acoustic"],
                artists: ["Bon Iver", "Phoebe Bridgers", "Fleet Foxes", "Noah Kahan", "Mumford & Sons", "The Lumineers", "Hozier", "Lord Huron", "Iron & Wine",
                          "Sufjan Stevens", "Novo Amor", "Gregory Alan Isakov", "José González", "Hippo Campus", "Mitski", "Big Thief", "Adrianne Lenker", "Julien Baker",
                          "Lucy Dacus", "boygenius", "Ben Howard", "Vance Joy", "The Head and the Heart", "Of Monsters and Men", "Passenger", "Zach Bryan"]),
        Cluster(vibes: ["sad songs", "big ballads", "2am feelings"],
                artists: ["LANY", "Lewis Capaldi", "Sam Smith", "Billie Eilish", "Joji", "Conan Gray", "Lauv", "Dean Lewis", "Alec Benjamin", "Ruel", "James Arthur",
                          "Adele", "Olivia Rodrigo", "Gracie Abrams", "Lizzy McAlpine", "Ben Platt", "Khalid", "Jeremy Zucker", "Chelsea Cutler", "Powfu",
                          "Mac Miller", "The Neighbourhood", "Daniel Caesar"]),
        Cluster(vibes: ["heavy rock", "metalcore", "gym rock"],
                artists: ["Linkin Park", "Bring Me The Horizon", "Falling In Reverse", "Sleep Token", "Bad Omens", "Spiritbox", "Architects", "Motionless In White",
                          "Ice Nine Kills", "Papa Roach", "Breaking Benjamin", "Three Days Grace", "Disturbed", "Five Finger Death Punch", "Rage Against the Machine",
                          "Korn", "System Of A Down", "Slipknot", "Skillet", "Avenged Sevenfold", "Metallica", "Pantera", "Gojira", "Lamb of God", "Parkway Drive",
                          "Imagine Dragons", "Starset", "Halestorm", "Evanescence", "Beartooth", "Wage War", "Polyphia"]),
        Cluster(vibes: ["Christian music", "faith-based pop", "worship"],
                artists: ["Lecrae", "for KING & COUNTRY", "Lauren Daigle", "Hillsong Worship", "Elevation Worship", "Bethel Music", "Chris Tomlin", "Casting Crowns",
                          "MercyMe", "Skillet", "NF", "Social Club Misfits", "KB", "Andy Mineo", "Tauren Wells", "TobyMac", "Switchfoot", "NEEDTOBREATHE",
                          "Brandon Lake", "Phil Wickham", "Maverick City Music", "Cory Asbury", "Matthew West", "Newsboys", "Crowder", "Zach Williams",
                          "Hillsong UNITED", "Cain", "Anne Wilson", "Forrest Frank", "Gawvi", "Hulvey", "Tedashii"]),
        Cluster(vibes: ["R&B", "smooth R&B", "soul"],
                artists: ["SZA", "Frank Ocean", "Daniel Caesar", "H.E.R.", "Steve Lacy", "Bruno Mars", "Anderson .Paak", "Brent Faiyaz", "Giveon", "Summer Walker",
                          "Jhené Aiko", "Khalid", "Lucky Daye", "Kali Uchis", "Childish Gambino", "The Weeknd", "Tems", "Mac Ayres", "Omar Apollo", "Raveena",
                          "Yebba", "Leon Bridges", "Jacob Collier", "Thundercat"]),
        Cluster(vibes: ["K-pop", "glossy K-pop", "catchy K-pop"],
                artists: ["BTS", "BLACKPINK", "NewJeans", "Stray Kids", "TWICE", "LE SSERAFIM", "(G)I-DLE", "aespa", "ITZY", "ATEEZ", "SEVENTEEN",
                          "TOMORROW X TOGETHER", "ENHYPEN", "IVE", "Red Velvet", "ILLIT", "BABYMONSTER", "ZEROBASEONE", "BOYNEXTDOOR", "Jungkook", "Jennie", "ROSÉ"]),
        Cluster(vibes: ["J-pop", "anime-energy J-pop", "Japanese pop"],
                artists: ["YOASOBI", "Ado", "Kenshi Yonezu", "LiSA", "Official HIGE DANdism", "Aimer", "Eve", "Yorushika", "ZUTOMAYO", "Fujii Kaze", "King Gnu",
                          "Hikaru Utada", "Vaundy", "Creepy Nuts", "Mrs. GREEN APPLE", "milet", "RADWIMPS", "ONE OK ROCK", "BABYMETAL", "Reol", "Kikuo"]),
        Cluster(vibes: ["reggaeton", "Latin pop", "Spanish bangers"],
                artists: ["Bad Bunny", "Rosalía", "KAROL G", "J Balvin", "Rauw Alejandro", "Peso Pluma", "Feid", "Anitta", "Shakira", "Maluma", "Ozuna", "Myke Towers",
                          "Daddy Yankee", "Becky G", "Natanael Cano", "Fuerza Regida", "Grupo Frontera", "Tini", "Camilo", "Sebastián Yatra"]),
        Cluster(vibes: ["country", "story-song country", "Americana"],
                artists: ["Morgan Wallen", "Luke Combs", "Zach Bryan", "Noah Kahan", "Chris Stapleton", "Kane Brown", "Luke Bryan", "Jason Aldean", "Tyler Childers",
                          "Sturgill Simpson", "Jelly Roll", "Bailey Zimmerman", "Thomas Rhett", "Dierks Bentley", "Cody Johnson", "Koe Wetzel", "Riley Green",
                          "Lainey Wilson", "Kacey Musgraves", "Old Dominion", "Dan + Shay"]),
        Cluster(vibes: ["classic rock", "rock anthems", "driving rock"],
                artists: ["Queen", "Led Zeppelin", "AC/DC", "Guns N' Roses", "Fleetwood Mac", "The Beatles", "Pink Floyd", "Journey", "Tom Petty and the Heartbreakers",
                          "Bruce Springsteen", "The Killers", "Foo Fighters", "Red Hot Chili Peppers", "Nirvana", "Pearl Jam", "Aerosmith", "Bon Jovi", "Def Leppard",
                          "Eagles", "Creedence Clearwater Revival", "The Rolling Stones", "Black Sabbath", "Van Halen"]),
        Cluster(vibes: ["funny songs", "comedy music", "silly but catchy"],
                artists: ["Weird Al Yankovic", "The Lonely Island", "Tenacious D", "Flight of the Conchords", "Bo Burnham", "Tom Cardy", "Ylvis", "Lemon Demon",
                          "Jack Stauber", "Neil Cicierega", "TWRP", "Starbomb", "Ninja Sex Party", "Dan Bull", "poptropicaslutz!"]),
        Cluster(vibes: ["chiptune", "game-soundtrack vibes", "boss-fight music"],
                artists: ["Toby Fox", "Lena Raine", "Anamanaguchi", "Chipzel", "Danimal Cannon", "Camellia", "C418", "Darren Korb", "Disasterpeace",
                          "Lemon Demon", "Jake Chudnow", "Porter Robinson"]),
    ]

    /// Short descriptions for artists that come up a lot; everyone else gets their style's description.
    static let blurbs: [String: String] = {
        let raw: [String: String] = [
            "100 gecs": "chaotic hyperpop",
            "Glaive": "emo-ish digicore",
            "Ericdoa": "punky digicore",
            "Underscores": "glitchy pop-punk",
            "2hollis": "hard club rap",
            "midwxst": "melodic digicore",
            "brakence": "frantic emo-pop",
            "osquinn": "bubbly digicore",
            "Jane Remover": "noisy digicore",
            "Dylan Brady": "100 gecs producer",
            "Laura Les": "100 gecs singer",
            "Charli XCX": "hyperpop-y pop star",
            "SOPHIE": "futuristic hyperpop",
            "A. G. Cook": "shiny PC Music pop",
            "Food House": "loud, silly hyperpop",
            "fraxiom": "punky hyperpop",
            "Machine Girl": "breakcore",
            "Dorian Electra": "theatrical synth-pop",
            "Alice Longyu Gao": "bratty hyperpop",
            "Ninajirachi": "sparkly electronic pop",
            "Danny L Harle": "euphoric PC Music",
            "Hannah Diamond": "glossy PC Music pop",
            "Rina Sawayama": "genre-mashing pop",
            "Slayyyter": "bratty electro-pop",
            "Kero Kero Bonito": "bubblegum pop",
            "Quadeca": "art rap",
            "Porter Robinson": "dreamy electronic",
            "Mura Masa": "bright electronic pop",
            "Poppy": "weird pop meets metal",
            "Frost Children": "rave-y hyperpop",
            "Lil Peep": "emo rap",
            "Juice WRLD": "melodic emo rap",
            "iann dior": "pop-punk rap",
            "Trippie Redd": "rock-ish rap",
            "nothing,nowhere.": "emo rap",
            "Yung Lean": "cloud rap",
            "Bladee": "icy cloud rap",
            "Ecco2k": "dreamy cloud pop",
            "Lil Tracy": "goth emo rap",
            "Ghostemane": "metal trap",
            "Lil Uzi Vert": "rock-star rap",
            "The Kid LAROI": "pop rap",
            "Powfu": "lo-fi rap",
            "Yeat": "rage rap",
            "Ken Carson": "rage rap",
            "Destroy Lonely": "rage rap",
            "JPEGMAFIA": "noisy experimental rap",
            "Danny Brown": "wild experimental rap",
            "Injury Reserve": "experimental rap",
            "clipping.": "noise rap",
            "Denzel Curry": "aggressive rap",
            "Tyler, The Creator": "colorful rap",
            "Brockhampton": "rap boyband",
            "Black Midi": "wild art rock",
            "Yves Tumor": "glam art rock",
            "Playboi Carti": "rage rap",
            "Joji": "sad lo-fi R&B",
            "girl in red": "indie pop",
            "Beabadoobee": "fuzzy guitar pop",
            "Clairo": "soft bedroom pop",
            "Cavetown": "cozy bedroom pop",
            "Wallows": "sunny indie rock",
            "Conan Gray": "big-chorus pop",
            "Laufey": "jazzy pop",
            "Rex Orange County": "warm bedroom pop",
            "Dayglow": "sunny synth pop",
            "Men I Trust": "dreamy indie",
            "Lovejoy": "fast indie rock",
            "Mitski": "dramatic indie rock",
            "Phoebe Bridgers": "sad indie folk",
            "AJR": "theatrical pop",
            "twenty one pilots": "alt-pop",
            "Mother Mother": "quirky alt-rock",
            "Jon Bellion": "big layered pop",
            "Klangkuenstler": "German techno",
            "Ski Aggu": "German rap + techno",
            "Anamanaguchi": "chiptune punk",
            "Lemon Demon": "nerdy synth-pop",
            "Jack Stauber": "weird lo-fi pop",
        ]
        var m: [String: String] = [:]
        for (k, v) in raw { m[normName(k)] = v }
        return m
    }()

    private static let indexed: [(members: [String: String], size: Int)] = clusters.map { c in
        var m: [String: String] = [:]
        for name in c.artists { m[normName(name)] = name }
        return (m, c.artists.count)
    }

    static func describe(_ c: Candidate) -> String {
        blurbs[normName(c.name)] ?? clusters[c.cluster].vibes.randomElement() ?? "something new"
    }

    /// Artists related to the ones in the playlist, best match first.
    static func similar(profile: [String: Int], exclude: Set<String>) -> [Candidate] {
        var weight: [String: Double] = [:]
        var name: [String: String] = [:]
        var best: [String: (Double, Int, [String])] = [:]
        for (ci, cl) in indexed.enumerated() {
            let matched = profile.filter { cl.members[$0.key] != nil }.sorted { $0.value > $1.value }.map { $0.key }
            let score = matched.reduce(0) { $0 + (profile[$1] ?? 0) }
            if score == 0 { continue }
            let contrib = Double(score) / sqrt(Double(cl.size))
            for (key, disp) in cl.members where !exclude.contains(key) {
                weight[key, default: 0] += contrib
                name[key] = disp
                if best[key] == nil || contrib > best[key]!.0 { best[key] = (contrib, ci, matched) }
            }
        }
        return weight.sorted { $0.value > $1.value }.map {
            Candidate(name: name[$0.key] ?? $0.key, weight: $0.value, cluster: best[$0.key]?.1 ?? 0, matched: best[$0.key]?.2 ?? [])
        }
    }
}

// MARK: - Pictures

enum ImageCache {
    static let cache = NSCache<NSString, NSImage>()
}

struct RemoteImage: View {
    let url: String
    var radius: CGFloat = 6
    var tint: Color = .gray
    @State private var image: NSImage?

    var body: some View {
        Color.clear
            .overlay(
                ZStack {
                    tint.opacity(0.25)
                    if let image { Image(nsImage: image).resizable().scaledToFill() }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .task(id: url) { await load() }
    }

    private func load() async {
        guard !url.isEmpty, let u = URL(string: url) else { image = nil; return }
        if let c = ImageCache.cache.object(forKey: url as NSString) { image = c; return }
        if let (d, _) = try? await URLSession.shared.data(from: u), let img = NSImage(data: d) {
            ImageCache.cache.setObject(img, forKey: url as NSString)
            image = img
        }
    }
}

// MARK: - Views

func mmss(_ s: Double) -> String {
    let t = max(0, Int(s.rounded()))
    return String(format: "%d:%02d", t / 60, t % 60)
}

struct IconButton: View {
    let symbol: String
    var size: CGFloat = 13
    var active = false
    var color: Color
    var activeColor: Color
    var help = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(active ? activeColor : color)
                .frame(width: size * 1.7, height: size * 1.7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct RootView: View {
    @ObservedObject var m: PlayerModel
    @State private var showColors = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let u = max(0.55, min(3.2, w / 340))
            let p = m.theme.palette
            ZStack(alignment: .bottom) {
                p.bg
                Group {
                    if m.conn != .connected {
                        ConnectView(m: m, p: p, u: u, tiny: h < 100 * u)
                    } else if h < 92 * u {
                        CompactView(m: m, p: p, u: u, h: h, showColors: $showColors)
                    } else {
                        VStack(spacing: 0) {
                            HeaderView(m: m, p: p, u: u, showColors: $showColors)
                            if h >= 235 * u && (m.showList || m.showDiscover) {
                                Rectangle().fill(p.line).frame(height: 1)
                                if m.showDiscover {
                                    DiscoverView(m: m, p: p, u: u)
                                } else {
                                    QueueListView(m: m, p: p, u: u)
                                }
                            } else {
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                if !m.toast.isEmpty {
                    Text(m.toast)
                        .font(.system(size: 11.5 * u, weight: .medium))
                        .foregroundColor(p.accentFg)
                        .padding(.horizontal, 10 * u).padding(.vertical, 6 * u)
                        .background(Capsule().fill(p.accent))
                        .padding(.bottom, 10 * u)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: m.toast)
            .frame(width: w, height: h)
        }
        .ignoresSafeArea()
        .contextMenu {
            if !m.now.title.isEmpty {
                Menu("Add “\(cleanTitle(m.now.title))” to playlist") {
                    ForEach(m.sortedPlaylists) { pl in Button(pl.title) { m.addToPlaylist(.current, pl) } }
                }
                Divider()
            }
            Button(m.pinned ? "Unpin (stop staying on top)" : "Pin on top") { m.pinned.toggle() }
            Button(m.showDiscover ? "Back to playlist" : "Find new music") { m.toggleDiscover() }
            Button(m.showList ? "Hide playlist" : "Show playlist") { m.toggleList() }
            Button("Colors…") { showColors = true }
            Menu("Also add every song to…") {
                Button((m.masterPlaylist.isEmpty ? "✓ " : "") + "Nothing extra") { m.masterPlaylist = "" }
                ForEach(m.sortedPlaylists) { pl in
                    Button((m.masterPlaylist == pl.title ? "✓ " : "") + pl.title) { m.masterPlaylist = pl.title }
                }
            }
            Divider()
            Button("Tip the developer on Venmo ☕") { m.openTip() }
            Button("Quit") { NSApp.terminate(nil) }
        }
    }

}

struct ToolButtons: View {
    @ObservedObject var m: PlayerModel
    let p: Palette
    let u: CGFloat
    @Binding var showColors: Bool
    var small = false

    var body: some View {
        let s: CGFloat = (small ? 10.5 : 12) * u
        HStack(spacing: 2 * u) {
            IconButton(symbol: m.pinned ? "pin.fill" : "pin.slash", size: s, active: m.pinned, color: p.sub, activeColor: p.accent,
                       help: m.pinned ? "Pinned on top — click to unpin" : "Click to keep this on top of everything") { m.pinned.toggle() }
            if !small {
                IconButton(symbol: "sparkles", size: s, active: m.showDiscover, color: p.sub, activeColor: p.accent, help: "Find new music") { m.toggleDiscover() }
                IconButton(symbol: "list.bullet", size: s, active: m.showList && !m.showDiscover, color: p.sub, activeColor: p.accent, help: "Playlist") { m.toggleList() }
            }
            IconButton(symbol: "paintpalette", size: s, active: showColors, color: p.sub, activeColor: p.accent, help: "Colors") { showColors.toggle() }
                .popover(isPresented: $showColors, arrowEdge: .bottom) { ColorEditor(m: m) }
            IconButton(symbol: "xmark", size: s * 0.9, color: p.sub, activeColor: p.accent, help: "Quit") { NSApp.terminate(nil) }
        }
    }
}

struct TransportButtons: View {
    @ObservedObject var m: PlayerModel
    let p: Palette
    let u: CGFloat
    var showExtras = true

    var body: some View {
        HStack(spacing: 10 * u) {
            if showExtras {
                IconButton(symbol: "shuffle", size: 13 * u, active: m.now.shuffle, color: p.sub, activeColor: p.accent, help: "Shuffle") { m.toggleShuffle() }
            }
            IconButton(symbol: "backward.fill", size: 16 * u, color: p.fg, activeColor: p.accent, help: "Previous") { m.previous() }
            Button(action: { m.playPause() }) {
                ZStack {
                    Circle().fill(p.accent)
                    Image(systemName: m.now.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 16 * u, weight: .bold))
                        .foregroundColor(p.accentFg)
                        .offset(x: m.now.playing ? 0 : 1 * u)
                }
                .frame(width: 38 * u, height: 38 * u)
            }
            .buttonStyle(.plain)
            .help(m.now.playing ? "Pause" : "Play")
            IconButton(symbol: "forward.fill", size: 16 * u, color: p.fg, activeColor: p.accent, help: "Next") { m.next() }
            if showExtras {
                IconButton(symbol: m.now.repeatMode == "ONE" ? "repeat.1" : "repeat", size: 13 * u, active: m.now.repeatMode != "NONE",
                           color: p.sub, activeColor: p.accent, help: "Repeat") { m.toggleRepeat() }
            }
        }
    }
}

struct ProgressBar: View {
    let value: Double, total: Double
    let p: Palette
    let u: CGFloat
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(p.fg.opacity(0.15))
                Capsule().fill(p.accent).frame(width: g.size.width * CGFloat(total > 0 ? min(1, value / total) : 0))
            }
        }
        .frame(height: 4 * u)
    }
}

struct HeaderView: View {
    @ObservedObject var m: PlayerModel
    let p: Palette
    let u: CGFloat
    @Binding var showColors: Bool
    @State private var showAdd = false

    var body: some View {
        HStack(alignment: .top, spacing: 12 * u) {
            RemoteImage(url: m.now.art, radius: 8 * u, tint: p.fg)
                .frame(width: 92 * u, height: 92 * u)
            VStack(alignment: .leading, spacing: 2 * u) {
                HStack(alignment: .top, spacing: 4 * u) {
                    VStack(alignment: .leading, spacing: 1 * u) {
                        HStack(spacing: 3 * u) {
                            Text(m.now.title.isEmpty ? "Nothing playing" : m.now.title)
                                .font(.system(size: 15 * u, weight: .bold)).foregroundColor(p.fg).lineLimit(1)
                            if !m.now.title.isEmpty {
                                IconButton(symbol: "plus.circle.fill", size: 13 * u, color: p.accent, activeColor: p.accent,
                                           help: "Add this song to a playlist") { showAdd.toggle() }
                                    .popover(isPresented: $showAdd, arrowEdge: .bottom) {
                                        PlaylistPicker(m: m, target: .current, songTitle: m.now.title, isOpen: $showAdd)
                                    }
                            }
                        }
                        Text(m.now.artist)
                            .font(.system(size: 12 * u)).foregroundColor(p.sub).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    ToolButtons(m: m, p: p, u: u, showColors: $showColors)
                }
                Spacer(minLength: 2 * u)
                HStack(spacing: 6 * u) {
                    Text(mmss(m.now.pos)).font(.system(size: 10 * u).monospacedDigit()).foregroundColor(p.sub)
                    ProgressBar(value: m.now.pos, total: m.now.dur, p: p, u: u)
                    Text(mmss(m.now.dur)).font(.system(size: 10 * u).monospacedDigit()).foregroundColor(p.sub)
                }
                HStack { Spacer(minLength: 0); TransportButtons(m: m, p: p, u: u); Spacer(minLength: 0) }
            }
            .frame(height: 92 * u)
        }
        .padding(12 * u)
    }
}

struct CompactView: View {
    @ObservedObject var m: PlayerModel
    let p: Palette
    let u: CGFloat
    let h: CGFloat
    @Binding var showColors: Bool
    @State private var showAdd = false

    var body: some View {
        let art = max(24, h - 20 * u)
        HStack(spacing: 10 * u) {
            RemoteImage(url: m.now.art, radius: 6 * u, tint: p.fg).frame(width: art, height: art)
            VStack(alignment: .leading, spacing: 2 * u) {
                Text(m.now.title.isEmpty ? "Nothing playing" : m.now.title)
                    .font(.system(size: 13 * u, weight: .bold)).foregroundColor(p.fg).lineLimit(1)
                Text(m.now.artist).font(.system(size: 11 * u)).foregroundColor(p.sub).lineLimit(1)
                ProgressBar(value: m.now.pos, total: m.now.dur, p: p, u: u)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6 * u) {
                IconButton(symbol: "backward.fill", size: 13 * u, color: p.fg, activeColor: p.accent) { m.previous() }
                Button(action: { m.playPause() }) {
                    ZStack {
                        Circle().fill(p.accent)
                        Image(systemName: m.now.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 12 * u, weight: .bold)).foregroundColor(p.accentFg)
                    }
                    .frame(width: 30 * u, height: 30 * u)
                }
                .buttonStyle(.plain)
                IconButton(symbol: "forward.fill", size: 13 * u, color: p.fg, activeColor: p.accent) { m.next() }
            }
            VStack(spacing: 0) {
                IconButton(symbol: m.pinned ? "pin.fill" : "pin.slash", size: 10 * u, active: m.pinned, color: p.sub, activeColor: p.accent) { m.pinned.toggle() }
                IconButton(symbol: "plus.circle.fill", size: 10 * u, color: p.accent, activeColor: p.accent, help: "Add this song to a playlist") { showAdd.toggle() }
                    .popover(isPresented: $showAdd, arrowEdge: .bottom) {
                        PlaylistPicker(m: m, target: .current, songTitle: m.now.title, isOpen: $showAdd)
                    }
                IconButton(symbol: "paintpalette", size: 10 * u, active: showColors, color: p.sub, activeColor: p.accent) { showColors.toggle() }
                    .popover(isPresented: $showColors, arrowEdge: .bottom) { ColorEditor(m: m) }
            }
        }
        .padding(.horizontal, 10 * u)
        .padding(.vertical, 6 * u)
    }
}

struct QueueListView: View {
    @ObservedObject var m: PlayerModel
    let p: Palette
    let u: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(m.now.container.isEmpty ? "Up next" : m.now.container)
                    .font(.system(size: 11 * u, weight: .semibold)).foregroundColor(p.sub).lineLimit(1)
                Spacer()
                Text("\(m.queue.count) songs").font(.system(size: 10 * u)).foregroundColor(p.sub)
            }
            .padding(.horizontal, 12 * u).padding(.vertical, 6 * u)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: true) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(m.queue.enumerated()), id: \.element.id) { i, item in
                            QueueRow(m: m, p: p, u: u, item: item, index: i)
                                .id(item.id)
                        }
                    }
                }
                .onAppear { scroll(proxy, animated: false) }
                .onChange(of: m.currentIndex) { _ in scroll(proxy, animated: true) }
                .onChange(of: m.queue.count) { _ in scroll(proxy, animated: false) }
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard m.currentIndex < m.queue.count else { return }
        let id = m.queue[m.currentIndex].id
        DispatchQueue.main.async {
            if animated { withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .top) } }
            else { proxy.scrollTo(id, anchor: .top) }
        }
    }
}

struct QueueRow: View {
    @ObservedObject var m: PlayerModel
    let p: Palette
    let u: CGFloat
    let item: QItem
    let index: Int
    @State private var hover = false

    var body: some View {
        let isCurrent = index == m.currentIndex
        let isPast = index < m.currentIndex
        let spot = m.lineup[item.id]
        HStack(spacing: 8 * u) {
            ZStack {
                RemoteImage(url: item.art, radius: 4 * u, tint: p.fg).frame(width: 32 * u, height: 32 * u)
                if isCurrent {
                    RoundedRectangle(cornerRadius: 4 * u).fill(Color.black.opacity(0.45)).frame(width: 32 * u, height: 32 * u)
                    Image(systemName: m.now.playing ? "waveform" : "pause.fill")
                        .font(.system(size: 11 * u, weight: .bold)).foregroundColor(.white)
                }
            }
            VStack(alignment: .leading, spacing: 1 * u) {
                Text(item.title)
                    .font(.system(size: 12 * u, weight: isCurrent ? .bold : .medium))
                    .foregroundColor(isCurrent ? p.accent : p.fg).lineLimit(1)
                Text(item.artist).font(.system(size: 10.5 * u)).foregroundColor(p.sub).lineLimit(1)
            }
            Spacer(minLength: 4 * u)
            if let spot {
                Text("\(spot)")
                    .font(.system(size: 10 * u, weight: .bold)).foregroundColor(p.accentFg)
                    .frame(width: 18 * u, height: 18 * u).background(Circle().fill(p.accent))
                    .help("Your line-up: #\(spot)")
            }
            if !isCurrent {
                HStack(spacing: 0) {
                    IconButton(symbol: "text.insert", size: 11 * u, color: p.sub, activeColor: p.accent, help: "Play next") { m.playNext(item) }
                    IconButton(symbol: "text.append", size: 11 * u, color: p.sub, activeColor: p.accent, help: "Add to queue (after the songs you already added)") { m.addToQueue(item) }
                }
                .opacity(hover ? 1 : 0.55)
            }
            Text(mmss(Double(item.duration))).font(.system(size: 10 * u).monospacedDigit()).foregroundColor(p.sub)
                .frame(width: 34 * u, alignment: .trailing)
        }
        .padding(.horizontal, 12 * u).padding(.vertical, 3 * u)
        .background(hover ? p.hover : (isCurrent ? p.accent.opacity(0.12) : Color.clear))
        .opacity(isPast ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { m.play(item) }
        .contextMenu {
            Button("Play now") { m.play(item) }
            Button("Play next") { m.playNext(item) }
            Button("Add to queue") { m.addToQueue(item) }
            PlaylistSubmenu(m: m, target: .queueItem(item.id))
            if spot != nil { Button("Remove from queue") { m.removeFromQueue(item) } }
        }
    }
}

struct DiscoverView: View {
    @ObservedObject var m: PlayerModel
    let p: Palette
    let u: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6 * u) {
                Image(systemName: "sparkles").font(.system(size: 11 * u, weight: .bold)).foregroundColor(p.accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Find new music").font(.system(size: 12 * u, weight: .bold)).foregroundColor(p.fg)
                    Text(m.discoverNote).font(.system(size: 10 * u)).foregroundColor(p.sub).lineLimit(1)
                }
                Spacer()
                if m.discovering { ProgressView().controlSize(.small).scaleEffect(0.8) }
                Button(action: { m.findNewMusic() }) {
                    Text("New picks")
                        .font(.system(size: 10.5 * u, weight: .semibold)).foregroundColor(p.accentFg)
                        .padding(.horizontal, 9 * u).padding(.vertical, 4 * u)
                        .background(Capsule().fill(p.accent))
                        .opacity(m.discovering ? 0.5 : 1)
                }
                .buttonStyle(.plain).disabled(m.discovering)
                IconButton(symbol: "xmark.circle.fill", size: 12 * u, color: p.sub, activeColor: p.accent, help: "Back to playlist") { m.showDiscover = false }
            }
            .padding(.horizontal, 12 * u).padding(.vertical, 7 * u)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(m.suggestions) { s in SuggestionRow(m: m, p: p, u: u, s: s) }
                    if m.suggestions.isEmpty && !m.discovering {
                        Text("Press “New picks” to find songs that aren't in this playlist yet.")
                            .font(.system(size: 11 * u)).foregroundColor(p.sub).padding(16 * u)
                    }
                }
            }
        }
    }
}

struct SuggestionRow: View {
    @ObservedObject var m: PlayerModel
    let p: Palette
    let u: CGFloat
    let s: Suggestion
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8 * u) {
            RemoteImage(url: s.art, radius: 4 * u, tint: p.fg).frame(width: 38 * u, height: 38 * u)
            VStack(alignment: .leading, spacing: 1 * u) {
                Text(s.title).font(.system(size: 12 * u, weight: .semibold)).foregroundColor(p.fg).lineLimit(1)
                Text(s.artist).font(.system(size: 10.5 * u)).foregroundColor(p.sub).lineLimit(1)
                Text(s.reason).font(.system(size: 10 * u, weight: .medium)).foregroundColor(p.accent).lineLimit(1)
            }
            Spacer(minLength: 4 * u)
            HStack(spacing: 0) {
                IconButton(symbol: "play.fill", size: 11 * u, color: p.fg, activeColor: p.accent, help: "Play now") { m.use(s, .play) }
                IconButton(symbol: "text.insert", size: 11 * u, color: p.fg, activeColor: p.accent, help: "Play next") { m.use(s, .next) }
                IconButton(symbol: "text.append", size: 11 * u, color: p.fg, activeColor: p.accent, help: "Add to queue") { m.use(s, .queue) }
            }
        }
        .padding(.horizontal, 12 * u).padding(.vertical, 4 * u)
        .background(hover ? p.hover : Color.clear)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Play now") { m.use(s, .play) }
            Button("Play next") { m.use(s, .next) }
            Button("Add to queue") { m.use(s, .queue) }
            PlaylistSubmenu(m: m, target: .suggestion(s.id))
        }
    }
}

/// List of your playlists to add a song to (recently used ones first).
struct PlaylistPicker: View {
    @ObservedObject var m: PlayerModel
    let target: PlayerModel.AddTarget
    let songTitle: String
    @Binding var isOpen: Bool
    @State private var filter = ""

    var body: some View {
        let list = m.sortedPlaylists.filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) }
        VStack(alignment: .leading, spacing: 8) {
            Text("Add “\(cleanTitle(songTitle))” to…").font(.headline).lineLimit(1)
            Picker("Also add every song to", selection: $m.masterPlaylist) {
                Text("Nothing extra").tag("")
                if !m.masterPlaylist.isEmpty && !m.playlists.contains(where: { $0.title == m.masterPlaylist }) {
                    Text(m.masterPlaylist).tag(m.masterPlaylist)
                }
                ForEach(m.playlists) { Text($0.title).tag($0.title) }
            }
            .pickerStyle(.menu).font(.caption)
            TextField("Search your playlists", text: $filter).textFieldStyle(.roundedBorder)
            if m.playlists.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Loading your playlists…").font(.caption) }
                    .task { await m.loadPlaylists() }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(list) { pl in
                        Button(action: { m.addToPlaylist(target, pl); isOpen = false }) {
                            HStack(spacing: 8) {
                                RemoteImage(url: pl.image, radius: 4).frame(width: 26, height: 26)
                                Text(pl.title).lineLimit(1)
                                if m.isRecent(pl) { Image(systemName: "clock").font(.caption2).foregroundColor(.secondary) }
                                Spacer()
                                Text("\(pl.count)").font(.caption).foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4).padding(.horizontal, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 280)
        }
        .padding(12)
        .frame(width: 280)
    }
}

/// "Add to playlist ▸" submenu for right-click menus.
struct PlaylistSubmenu: View {
    @ObservedObject var m: PlayerModel
    let target: PlayerModel.AddTarget
    var body: some View {
        Menu("Add to playlist") {
            if m.playlists.isEmpty { Text("Loading playlists…") }
            ForEach(m.sortedPlaylists) { pl in
                Button(pl.title) { m.addToPlaylist(target, pl) }
            }
        }
    }
}

struct ConnectView: View {
    @ObservedObject var m: PlayerModel
    let p: Palette
    let u: CGFloat
    let tiny: Bool

    var body: some View {
        VStack(spacing: 8 * u) {
            if m.conn == .needsRestart {
                if !tiny {
                    Text("Amazon Music needs a quick restart so this player can control it.")
                        .font(.system(size: 12 * u)).foregroundColor(p.fg).multilineTextAlignment(.center)
                }
                Button(action: { m.restartAmazon() }) {
                    Text("Connect").font(.system(size: 13 * u, weight: .bold)).foregroundColor(p.accentFg)
                        .padding(.horizontal, 18 * u).padding(.vertical, 7 * u).background(Capsule().fill(p.accent))
                }
                .buttonStyle(.plain)
                if !tiny {
                    Text("Your music pauses for a few seconds.").font(.system(size: 10 * u)).foregroundColor(p.sub)
                }
            } else {
                ProgressView().controlSize(.small)
                Text(m.conn == .restarting ? "Restarting Amazon Music…" : "Connecting to Amazon Music…")
                    .font(.system(size: 12 * u)).foregroundColor(p.sub)
            }
        }
        .padding(14 * u)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ColorEditor: View {
    @ObservedObject var m: PlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Colors").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(54), spacing: 8), count: 4), spacing: 8) {
                ForEach(Theme.presets, id: \.name) { t in
                    Button(action: { m.theme = t }) {
                        VStack(spacing: 3) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8).fill(t.bg.color)
                                Circle().fill(t.accent.color).frame(width: 16, height: 16)
                            }
                            .frame(width: 54, height: 34)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(m.theme.name == t.name ? Color.accentColor : Color.gray.opacity(0.4), lineWidth: m.theme.name == t.name ? 2 : 1))
                            Text(t.name).font(.system(size: 9)).foregroundColor(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            sliders("Background", Binding(get: { m.theme.bg }, set: { m.theme.bg = $0; m.theme.name = "Custom" }))
            sliders("Buttons & highlight", Binding(get: { m.theme.accent }, set: { m.theme.accent = $0; m.theme.name = "Custom" }))
            HStack {
                Text("See-through").font(.caption).frame(width: 96, alignment: .leading)
                Slider(value: Binding(get: { 1 - m.theme.opacity }, set: { m.theme.opacity = 1 - $0; m.theme.name = "Custom" }), in: 0...0.7)
            }
            Divider()
            Button(action: { m.openTip() }) {
                Label("Like Mini Player? Tip on Venmo", systemImage: "cup.and.saucer.fill").font(.caption)
            }
            .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 270)
    }

    private func sliders(_ title: String, _ b: Binding<HSB>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.bold())
            HStack { Text("Color").font(.caption).frame(width: 60, alignment: .leading); Slider(value: b.h, in: 0...1) }
            HStack { Text("Richness").font(.caption).frame(width: 60, alignment: .leading); Slider(value: b.s, in: 0...1) }
            HStack { Text("Brightness").font(.caption).frame(width: 60, alignment: .leading); Slider(value: b.b, in: 0...1) }
        }
    }
}

// MARK: - Window (always on top, resizable)

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = PlayerModel()
    var panel: FloatingPanel!
    var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()

        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 150, height: 54)
        panel.title = "Mini Player"

        let host = NSHostingView(rootView: RootView(m: model))
        if #available(macOS 13.0, *) { host.sizingOptions = [] }
        panel.contentView = host
        panel.setFrameAutosaveName("MiniPlayerWindow")
        if !panel.setFrameUsingName("MiniPlayerWindow") {
            panel.center()
        }
        self.panel = panel
        applyPin(model.pinned)
        panel.orderFrontRegardless()

        model.$pinned.sink { [weak self] in self?.applyPin($0) }.store(in: &bag)
        model.wantsRoomForList = { [weak self] show in self?.makeRoom(forList: show) }
        if let dir = ProcessInfo.processInfo.environment["MINIPLAYER_TEST_DIR"] { startTestHarness(dir) }
    }

    // Test mode (only when MINIPLAYER_TEST_DIR is set): reads commands from cmd.txt, writes snap.png + state.txt.
    func startTestHarness(_ dir: String) {
        let base = URL(fileURLWithPath: dir)
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let cmdURL = base.appendingPathComponent("cmd.txt")
                guard let cmd = try? String(contentsOf: cmdURL, encoding: .utf8) else { return }
                try? FileManager.default.removeItem(at: cmdURL)
                for line in cmd.split(separator: "\n") { self.runTest(String(line), base) }
            }
        }
    }

    func runTest(_ line: String, _ base: URL) {
        let a = line.split(separator: " ").map(String.init)
        guard let c = a.first else { return }
        let n = a.count > 1 ? Int(a[1]) ?? 0 : 0
        let m = model
        switch c {
        case "resize": panel.setContentSize(NSSize(width: n, height: Int(a[2]) ?? 100))
        case "frame": if a.count == 5, let x = Double(a[1]), let y = Double(a[2]), let w = Double(a[3]), let h = Double(a[4]) {
            panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true) }
        case "next": m.next()
        case "prev": m.previous()
        case "playpause": m.playPause()
        case "play": if n < m.queue.count { m.play(m.queue[n]) }
        case "playnext": if n < m.queue.count { m.playNext(m.queue[n]) }
        case "queue": if n < m.queue.count { m.addToQueue(m.queue[n]) }
        case "remove": if n < m.queue.count { m.removeFromQueue(m.queue[n]) }
        case "discover": m.findNewMusic()
        case "connect": m.restartAmazon()
        case "playlists": Task { await m.loadPlaylists() }
        case "addpl":
            let name = a.dropFirst().joined(separator: " ")
            if let pl = m.playlists.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) { m.addToPlaylist(.current, pl) }
        case "back": m.showDiscover = false
        case "use": if n < m.suggestions.count { m.use(m.suggestions[n], a[2] == "play" ? .play : a[2] == "next" ? .next : .queue) }
        case "theme": if let t = Theme.presets.first(where: { $0.name == a[1] }) { m.theme = t }
        case "opacity": m.theme.opacity = Double(a[1]) ?? 1
        case "pin": m.pinned = a[1] == "on"
        case "list": if (a[1] == "on") != m.showList || m.showDiscover { m.toggleList() }
        case "snap":
            guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: base.appendingPathComponent(a.count > 1 ? a[1] : "snap.png"))
        case "state":
            var s = "conn=\(m.conn) pinned=\(m.pinned) level=\(panel.level.rawValue) frame=\(panel.frame)\n"
            s += "now=\(m.now.title) | \(m.now.artist) | playing=\(m.now.playing) pos=\(Int(m.now.pos))/\(Int(m.now.dur)) shuffle=\(m.now.shuffle) container=\(m.now.container)\n"
            s += "cur=\(m.currentIndex) count=\(m.queue.count) lineup=\(m.lineup.sorted { $0.value < $1.value }.map { "\($0.value):\($0.key)" })\n"
            for i in max(0, m.currentIndex - 1)..<min(m.queue.count, m.currentIndex + 8) {
                s += "  [\(i)] \(m.queue[i].title) — \(m.queue[i].artist) \(m.lineup[m.queue[i].id].map { "(#\($0))" } ?? "")\n"
            }
            s += "discover=\(m.showDiscover) busy=\(m.discovering) note=\(m.discoverNote)\n"
            for (i, sg) in m.suggestions.enumerated() { s += "  {\(i)} \(sg.title) — \(sg.artist) [\(sg.reason)]\n" }
            s += "toast=\(m.toast)\n"
            try? s.write(to: base.appendingPathComponent(a.count > 1 ? a[1] : "state.txt"), atomically: true, encoding: .utf8)
        default: break
        }
    }

    /// Grows the window when the playlist is turned on but there's no room for it, and shrinks it when turned off.
    func makeRoom(forList show: Bool) {
        guard let panel else { return }
        let content = panel.contentRect(forFrameRect: panel.frame)
        let u = max(0.55, min(3.2, content.width / 340))
        let target: CGFloat
        if show {
            guard content.height < 235 * u else { return }
            target = 480 * u
        } else {
            guard content.height > 140 * u else { return }
            target = 116 * u
        }
        var r = panel.frameRect(forContentRect: NSRect(x: content.minX, y: content.maxY - target, width: content.width, height: target))
        if let vis = panel.screen?.visibleFrame, r.minY < vis.minY {
            r.origin.y = vis.minY
            r.size.height = min(r.height, vis.height)
        }
        panel.setFrame(r, display: true, animate: true)
    }

    func applyPin(_ pinned: Bool) {
        guard let panel else { return }
        if pinned {
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        } else {
            panel.level = .normal
            panel.collectionBehavior = [.managed, .fullScreenAuxiliary]
        }
        panel.orderFrontRegardless()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }  // pop-ups closing must not quit the app

    @objc func togglePin() { model.pinned.toggle() }
    @objc func quit() { NSApp.terminate(nil) }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Mini Player", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let pin = NSMenuItem(title: "Pin on Top / Unpin", action: #selector(togglePin), keyEquivalent: "p")
        pin.target = self
        viewMenu.addItem(pin)
        viewItem.submenu = viewMenu
        NSApp.mainMenu = main
    }
}

@main
struct MiniPlayerApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
