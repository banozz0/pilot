//! pilot-files: the Hyper+Space menu's file index (story 77, card agent-bo-95422765).
//!
//! Pilot runs it from Contents/Helpers and talks over pipes: each line on stdin is a search, each line on stdout a
//! JSON answer. It walks the root once (or reads the cache the last run left), then follows FSEvents, so a new
//! file is found within the stream's latency and nothing is walked again. Stdin closing means Pilot is gone or
//! stopped it (FileIndex.idleStop): the index is saved with the last event id applied, and the helper exits; the
//! next run replays FSEvents from that id, so changes made while it was stopped are applied.
//!
//!   pilot-files [--root DIR] [--cache FILE] [--ignore LINES]
//!
//! `--ignore` is the never-index list, gitignore lines relative to the root, one per line (empty: index everything);
//! without it, DEFAULT_IGNORE. A different list than the saved index's walks again (Cardinal keeps the list with it).
//!
//! First line out: {"ready":true,"files":N,"walked":bool,"ms":N}. Then per search, a bare line or a JSON request with
//! the Files view's filters (filter.rs): {"id":N,"query":"…","files":[{"path":"…","modified":unix seconds|null,"from":"…"}]}
//! (`id` only when the request had one) or, when Cardinal's syntax rejects it, {"query":"…","files":[],"error":"…"}.
//! Dot names and bundle insides are left out unless the request says `"hidden":true`. A search replaced by a newer one
//! before it finishes gets no answer. `from` is where the file came from (source.rs), left out when unknown; a request's
//! `"from":"whatsapp"` keeps only files whose source holds it, before the limit.
//!
//! `{"id":N,"dupes":true}` asks for identical files instead (dupes.rs); its answer comes once the files are read,
//! with searches answered meanwhile.
//!
//! The engine is Cardinal's (vendor/cardinal, MIT); its dev CLI `lsf` is the shape this follows.

mod dupes;
mod filter;
mod rank;
mod source;
mod typo;

use cardinal_sdk::EventWatcher;
use crossbeam_channel::{Receiver, select, unbounded};
use search_cache::{HandleFSEError, SearchCache, SearchOptions};
use search_cancel::CancellationToken;
use serde::Serialize;
use std::{
    io::{BufRead, Write},
    path::{Path, PathBuf},
    sync::atomic::AtomicBool,
    time::{Duration, Instant},
};

static NEVER_STOPPED: AtomicBool = AtomicBool::new(false);
/// FSEvents batches a second of changes: fast enough for a file saved a moment ago, quiet while ~/Library churns.
const LATENCY_SECONDS: f64 = 1.0;
/// Files per answer: the menu lists 20.
const LIMIT: usize = 20;
/// Gitignore lines, relative to the root (Cardinal's IgnoreMatcher), never indexed: Pilot's default never-index list
/// (FileExclusions.defaults), which Pilot passes with `--ignore`. ~/Library is app state and caches but for iCloud Drive
/// (Mobile Documents), ~/.Trash is gone, the dot folders are package caches and the rest another tool's thousands of
/// files: none is opened from a launcher.
const DEFAULT_IGNORE: &[&str] = &[
    "/Library/*", "!/Library/Mobile Documents/", "/.Trash/", "/.cache/", "/.bun/", "/.npm/", "/.cargo/", "/.rustup/",
    "node_modules/", ".git/", ".build/", "DerivedData/", "target/", "__pycache__/", "venv/", ".venv/",
];

struct Config {
    root: PathBuf,
    cache: PathBuf,
    ignore: Vec<PathBuf>,
}

fn config() -> Result<Config, String> {
    let home = PathBuf::from(std::env::var_os("HOME").ok_or("HOME is not set")?);
    let mut args = std::env::args().skip(1);
    let (mut root, mut cache) = (home.clone(), home.join("Library/Application Support/Pilot/files.cache"));
    let mut ignore: Vec<PathBuf> = DEFAULT_IGNORE.iter().map(PathBuf::from).collect();
    while let Some(flag) = args.next() {
        let value = args.next().ok_or(format!("{flag} needs a value"))?;
        match flag.as_str() {
            "--root" => root = value.into(),
            "--cache" => cache = value.into(),
            "--ignore" => ignore = value.lines().map(str::trim).filter(|l| !l.is_empty()).map(PathBuf::from).collect(),
            _ => return Err(format!("unknown flag {flag}")),
        }
    }
    Ok(Config { root, cache, ignore })
}

#[derive(Serialize)]
struct Ready {
    ready: bool,
    files: usize,
    walked: bool,
    ms: u128,
}

#[derive(Serialize)]
struct Answer<'a> {
    #[serde(skip_serializing_if = "Option::is_none")]
    id: Option<u64>,
    query: &'a str,
    files: Vec<Hit>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

#[derive(Serialize)]
struct Hit {
    path: String,
    modified: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    from: Option<String>,
}

fn main() {
    let config = match config() {
        Ok(config) => config,
        Err(message) => {
            eprintln!("pilot-files: {message}");
            std::process::exit(2);
        }
    };
    let started = Instant::now();
    let (mut cache, walked) =
        match SearchCache::try_read_persistent_cache(&config.root, &config.cache, &config.ignore, &NEVER_STOPPED) {
            Ok(cache) => (cache, false),
            Err(_) => (SearchCache::walk_fs_with_ignore(&config.root, &config.ignore), true),
        };
    let files = cache.get_total_files();
    send(&Ready { ready: true, files, walked, ms: started.elapsed().as_millis() });
    if walked {
        // Saved at once, so a crash before the first quit still spares the next start a walk.
        save(&mut cache, &config.cache);
    }

    let (searches, scans) = read_stdin();
    serve(&mut cache, &config, &searches, &scans);
    save(&mut cache, &config.cache);
}

/// Each stdin line is a search; reading it makes it the active one, so the search running cancels itself. A
/// duplicates scan goes on its own channel, so it neither cancels a search nor is dropped for a newer one.
fn read_stdin() -> (Receiver<(String, CancellationToken)>, Receiver<dupes::Scan>) {
    let (tx, rx) = unbounded();
    let (scan_tx, scan_rx) = unbounded();
    std::thread::spawn(move || {
        for (version, line) in std::io::stdin().lock().lines().map_while(Result::ok).enumerate() {
            let sent = match dupes::Scan::parse(&line) {
                Some(scan) => scan_tx.send(scan).is_ok(),
                None => tx.send((line, CancellationToken::new(version as u64 + 1))).is_ok(),
            };
            if !sent {
                break;
            }
        }
    });
    (rx, scan_rx)
}

/// Answers searches and applies file changes until stdin closes; a duplicates scan sizes its files a step at a time
/// whenever neither is waiting.
fn serve(cache: &mut SearchCache, config: &Config, searches: &Receiver<(String, CancellationToken)>, scans: &Receiver<dupes::Scan>) {
    let watch = |cache: &mut SearchCache| {
        EventWatcher::spawn(config.root.to_string_lossy().into_owned(), cache.last_event_id(), LATENCY_SECONDS, cache.ignore_paths()).1
    };
    let mut watcher = watch(cache);
    let mut sizing: Option<dupes::Sizing> = None;
    loop {
        let idle = if sizing.is_some() { Duration::ZERO } else { Duration::from_secs(3600) };
        select! {
            recv(searches) -> search => {
                let Ok(mut search) = search else { return };
                // Only the newest search matters: the menu has moved on from the rest.
                while let Ok(newer) = searches.try_recv() {
                    search = newer;
                }
                if let Some(answer) = answer(cache, config, &filter::Request::parse(&search.0), search.1) {
                    send(&answer);
                }
            }
            recv(watcher) -> events => {
                let Ok(events) = events else { continue };
                if let Err(HandleFSEError::Rescan) = cache.handle_fs_events(events) {
                    // FSEvents dropped history (a volume event, a full queue): walk again, as Cardinal does.
                    // The old stream stops before the walk, so its backlog does not pile up behind it.
                    drop(std::mem::replace(&mut watcher, EventWatcher::noop()));
                    cache.rescan();
                    watcher = watch(cache);
                }
            }
            recv(scans) -> scan => {
                let Ok(scan) = scan else { continue };
                sizing = Some(dupes::Sizing::start(cache, scan));
            }
            default(idle) => {
                if sizing.as_mut().is_some_and(|s| s.step(cache, &config.root)) {
                    sizing = None;
                }
            }
        }
    }
}

/// None when a newer search cancelled this one. The typed words find the names and the filters' terms narrow them;
/// a typo retry keeps the filters. An empty search answers nothing rather than list every file a filter takes.
fn answer<'q>(cache: &mut SearchCache, config: &Config, request: &'q filter::Request, cancel: CancellationToken) -> Option<Answer<'q>> {
    let (id, query) = (request.id, request.query.as_str());
    if query.trim().is_empty() {
        return Some(Answer { id, query, files: vec![], error: None });
    }
    let options = SearchOptions { case_insensitive: true };
    let terms = request.terms(&config.root);
    let mut nodes = match cache.search_with_options(&format!("{query}{terms}"), options, cancel) {
        Ok(outcome) => outcome.nodes?,
        Err(error) => return Some(Answer { id, query, files: vec![], error: Some(error.to_string()) }),
    };
    // Nothing as typed: once more forgiving typos (typo.rs), one pass over the names, then the filters on those.
    let typos = if nodes.is_empty() { typo::Typos::parse(query) } else { None };
    if let Some(typos) = &typos {
        let named = cache.nodes_named(|letters| typos.may(letters), |name| typos.matches(name), cancel)?;
        // A filter line Cardinal refuses answers nothing rather than leave the menu waiting; cancelled answers none.
        nodes = cache.search_within(named, &terms, options, cancel).unwrap_or(Some(vec![]))?;
    }
    let words = rank::words(query);
    let mut ranked = Vec::with_capacity(nodes.len());
    for (i, index) in nodes.into_iter().enumerate() {
        cancel.is_cancelled_sparse(i)?;
        if let Some(path) = cache.node_path(index) {
            let rel = path.strip_prefix(&config.root).unwrap_or(&path);
            if request.hidden || !filter::hidden(rel) {
                ranked.push((rank::score(rel, &words, typos.as_ref()), index, path));
            }
        }
    }
    ranked.sort_by(|a, b| b.0.cmp(&a.0).then(a.2.as_os_str().len().cmp(&b.2.as_os_str().len())));
    // Each source is read in rank order until the limit is full: 20 reads without `from`, as many as it takes with it.
    let from = request.from.as_deref().map(str::trim).filter(|f| !f.is_empty()).map(str::to_lowercase);
    let mut kept = Vec::with_capacity(LIMIT);
    for (i, (_, index, path)) in ranked.into_iter().enumerate() {
        if kept.len() == LIMIT {
            break;
        }
        // Two attribute reads a file: a newer search is checked for far more often than in the name pass.
        if i % 256 == 0 {
            cancel.is_cancelled()?;
        }
        let source = source::read(&path);
        if from.as_deref().is_none_or(|from| source::matches(source.as_deref(), from)) {
            kept.push((index, source));
        }
    }
    let (indices, sources): (Vec<_>, Vec<_>) = kept.into_iter().unzip();
    let files = cache
        .expand_file_nodes(&indices)
        .into_iter()
        .zip(sources)
        .map(|(node, from)| Hit {
            modified: node.metadata.as_ref().and_then(|m| m.mtime()).map(|t| u64::from(t.get())),
            path: node.path.to_string_lossy().into_owned(),
            from,
        })
        .collect();
    Some(Answer { id, query, files, error: None })
}

fn save(cache: &mut SearchCache, path: &Path) {
    if let Some(folder) = path.parent() {
        let _ = std::fs::create_dir_all(folder);
    }
    if let Err(error) = cache.flush_snapshot_to_file(path) {
        eprintln!("pilot-files: could not save the index to {}: {error}", path.display());
    }
}

/// One JSON line out; a scan's reading thread writes its answer here too, a whole line at a time.
fn send(value: &impl Serialize) {
    let mut out = std::io::stdout().lock();
    let _ = serde_json::to_writer(&mut out, value);
    let _ = out.write_all(b"\n");
    let _ = out.flush();
}
