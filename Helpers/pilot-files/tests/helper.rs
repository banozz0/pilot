//! The helper as Pilot sees it: a child process on pipes over a scratch root (card agent-bo-95422765, criteria 2
//! to 4). Real FSEvents, so each wait is bounded by the 2 s the card allows plus slack for a loaded machine.

use std::{
    io::{BufRead, BufReader, Write},
    path::Path,
    process::{Child, ChildStdin, ChildStdout, Command, Stdio},
    time::{Duration, Instant},
};

struct Helper {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

impl Helper {
    fn start(root: &Path, cache: &Path) -> (Self, serde_json::Value) {
        Self::start_with(root, cache, &[])
    }

    fn start_with(root: &Path, cache: &Path, more: &[&str]) -> (Self, serde_json::Value) {
        let mut child = Command::new(env!("CARGO_BIN_EXE_pilot-files"))
            .args(["--root", root.to_str().unwrap(), "--cache", cache.to_str().unwrap()])
            .args(more)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let stdin = child.stdin.take().unwrap();
        let mut helper = Helper { stdout: BufReader::new(child.stdout.take().unwrap()), stdin, child };
        let ready = helper.line();
        (helper, ready)
    }

    fn line(&mut self) -> serde_json::Value {
        let mut line = String::new();
        self.stdout.read_line(&mut line).unwrap();
        serde_json::from_str(&line).unwrap_or_else(|_| panic!("not JSON: {line:?}"))
    }

    fn paths(&mut self, query: &str) -> Vec<String> {
        writeln!(self.stdin, "{query}").unwrap();
        let answer = self.line();
        assert_eq!(answer["query"], query);
        answer["files"].as_array().unwrap().iter().map(|f| f["path"].as_str().unwrap().to_string()).collect()
    }

    /// A JSON request with the Files view's filters; the answer's paths under `root`, and its id.
    fn ask(&mut self, request: serde_json::Value, root: &Path) -> (Vec<String>, serde_json::Value) {
        writeln!(self.stdin, "{request}").unwrap();
        let answer = self.line();
        let mut paths: Vec<String> = answer["files"].as_array().unwrap().iter()
            .map(|f| f["path"].as_str().unwrap().strip_prefix(&format!("{}/", root.display())).unwrap().to_string())
            .collect();
        paths.sort();
        (paths, answer["id"].clone())
    }

    /// Asks until `done` holds, at most `within`; returns how long it took.
    fn until(&mut self, query: &str, within: Duration, done: impl Fn(&[String]) -> bool) -> Duration {
        let start = Instant::now();
        loop {
            if done(&self.paths(query)) {
                return start.elapsed();
            }
            assert!(start.elapsed() < within, "{query}: not seen within {within:?}");
            std::thread::sleep(Duration::from_millis(100));
        }
    }

    /// Closes stdin, as Pilot quitting does, and waits for the helper to save and exit.
    fn quit(mut self) {
        drop(self.stdin);
        assert!(self.child.wait().unwrap().success());
    }
}

#[test]
fn finds_a_file_follows_changes_and_reuses_its_cache() {
    let scratch = tempfile::tempdir().unwrap();
    let root = scratch.path().canonicalize().unwrap().join("home");
    let cache = scratch.path().join("files.cache");
    for dir in ["Documents/deep", "Library/Caches", ".Trash", "code/app/node_modules"] {
        std::fs::create_dir_all(root.join(dir)).unwrap();
    }
    for file in ["Documents/zqx-budget.xlsx", "Library/Caches/zqx-budget.cache", ".Trash/zqx-budget.old",
                 "code/app/node_modules/zqx-budget.js"] {
        std::fs::write(root.join(file), b"x").unwrap();
    }

    let (mut helper, ready) = Helper::start(&root, &cache);
    assert_eq!(ready["walked"], true);
    // The unique name is found, and nothing from ~/Library, ~/.Trash or node_modules.
    assert_eq!(helper.paths("zqx-budget"), [root.join("Documents/zqx-budget.xlsx").to_str().unwrap()]);
    // A typo that finds nothing is asked again as its likely fixes: swapped, missing, extra letter.
    for typo in ["zqx-bugdet", "zqx-budet", "zqx-buddget"] {
        assert_eq!(helper.paths(typo), [root.join("Documents/zqx-budget.xlsx").to_str().unwrap()], "{typo}");
    }

    // A file made after the walk arrives through FSEvents, and one deleted leaves.
    let late = root.join("Documents/deep/zqx-late.txt");
    std::fs::write(&late, b"x").unwrap();
    let late_str = late.to_str().unwrap().to_string();
    let seen = helper.until("zqx-late", Duration::from_secs(4), |p| p.contains(&late_str));
    std::fs::remove_file(&late).unwrap();
    let gone = helper.until("zqx-late", Duration::from_secs(4), |p| p.is_empty());
    eprintln!("created seen after {seen:?}, deleted gone after {gone:?}");
    assert!(seen < Duration::from_secs(2) && gone < Duration::from_secs(2));
    helper.quit();

    // The second start reads the saved index instead of walking.
    let (mut again, ready) = Helper::start(&root, &cache);
    assert_eq!(ready["walked"], false);
    assert_eq!(again.paths("zqx-budget").len(), 1);
    again.quit();
}

#[test]
fn ranks_the_name_first_and_keeps_its_limit() {
    let scratch = tempfile::tempdir().unwrap();
    let root = scratch.path().canonicalize().unwrap();
    std::fs::create_dir_all(root.join("a/b/c/vendor")).unwrap();
    for i in 0..30 {
        std::fs::write(root.join(format!("a/b/c/vendor/report-{i}.md")), b"x").unwrap();
    }
    std::fs::write(root.join("a/b/old report.md"), b"x").unwrap();
    std::fs::write(root.join("a/report.md"), b"x").unwrap();
    let (mut helper, _) = Helper::start(&root, &root.join("files.cache"));
    let paths = helper.paths("report");
    assert_eq!(paths.len(), 20);
    assert_eq!(paths[..2], [root.join("a/report.md").to_str().unwrap(), root.join("a/b/old report.md").to_str().unwrap()]);
    helper.quit();
}

fn tree(root: &Path, files: &[&str]) {
    for file in files {
        let path = root.join(file);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, b"x").unwrap();
    }
}

#[test]
fn hides_junk_unless_asked_and_keeps_icloud_drive() {
    let scratch = tempfile::tempdir().unwrap();
    let root = scratch.path().canonicalize().unwrap().join("home");
    tree(&root, &["Documents/zqj-notes.md", ".config/zqj-tool/zqj-conf.toml", "Applications/Zqj.app/Contents/zqj-info.plist",
                  "code/app/target/zqj-build.rs", "code/app/.git/zqj-head", "Library/Caches/zqj-cache.db",
                  "Library/Mobile Documents/com~apple~CloudDocs/zqj-cloud.md", "code/py/lib/site-packages/zqj-pkg.py"]);
    let (mut helper, _) = Helper::start(&root, &scratch.path().join("files.cache"));
    // Dot folders, bundle insides and site-packages are left out; target, .git and ~/Library (all but iCloud Drive)
    // were never indexed.
    let (paths, id) = helper.ask(serde_json::json!({"id": 1, "query": "zqj"}), &root);
    assert_eq!(id, 1);
    assert_eq!(paths, ["Applications/Zqj.app", "Documents/zqj-notes.md", "Library/Mobile Documents/com~apple~CloudDocs/zqj-cloud.md"]);
    // Show hidden brings back what the index holds.
    let (paths, _) = helper.ask(serde_json::json!({"id": 2, "query": "zqj", "hidden": true}), &root);
    assert!(paths.contains(&".config/zqj-tool/zqj-conf.toml".to_string()) && paths.contains(&"Applications/Zqj.app/Contents/zqj-info.plist".to_string()));
    assert!(!paths.iter().any(|p| p.contains("target") || p.contains(".git/") || p.contains("Caches")), "{paths:?}");
    // A bare line still answers, with junk hidden and no id.
    assert_eq!(helper.paths("zqj-conf"), Vec::<String>::new());
    helper.quit();

    // An empty never-index list indexes everything: a new list walks again.
    let (mut all, ready) = Helper::start_with(&root, &scratch.path().join("files.cache"), &["--ignore", ""]);
    assert_eq!(ready["walked"], true);
    let (paths, _) = all.ask(serde_json::json!({"query": "zqj-cache", "hidden": true}), &root);
    assert_eq!(paths, ["Library/Caches/zqj-cache.db"]);
    all.quit();
}

#[test]
fn filters_by_kind_folder_and_date() {
    let scratch = tempfile::tempdir().unwrap();
    let root = scratch.path().canonicalize().unwrap().join("home");
    tree(&root, &["Documents/zqk report.pdf", "Documents/zqk photo.png", "Downloads/zqk report.docx", "Downloads/zqk clip.mov",
                  "Downloads/zqk tunes.mp3", "code/zqk.rs", "Downloads/zqk.zip", "Applications/Zqk.app/Contents/x"]);
    std::fs::create_dir_all(root.join("Documents/zqk folder")).unwrap();
    // One file edited long ago: When leaves it out.
    let old = std::fs::File::options().write(true).open(root.join("Downloads/zqk.zip")).unwrap();
    old.set_modified(std::time::SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000_000)).unwrap();
    let (mut helper, _) = Helper::start(&root, &scratch.path().join("files.cache"));
    let ask = |helper: &mut Helper, filters: serde_json::Value| {
        let mut request = serde_json::json!({"query": "zqk"});
        request.as_object_mut().unwrap().extend(filters.as_object().unwrap().clone());
        helper.ask(request, &root).0
    };
    assert_eq!(ask(&mut helper, serde_json::json!({"kind": "documents"})), ["Documents/zqk report.pdf", "Downloads/zqk report.docx"]);
    assert_eq!(ask(&mut helper, serde_json::json!({"kind": "images"})), ["Documents/zqk photo.png"]);
    assert_eq!(ask(&mut helper, serde_json::json!({"kind": "video"})), ["Downloads/zqk clip.mov"]);
    assert_eq!(ask(&mut helper, serde_json::json!({"kind": "audio"})), ["Downloads/zqk tunes.mp3"]);
    assert_eq!(ask(&mut helper, serde_json::json!({"kind": "code"})), ["code/zqk.rs"]);
    assert_eq!(ask(&mut helper, serde_json::json!({"kind": "archives"})), ["Downloads/zqk.zip"]);
    assert_eq!(ask(&mut helper, serde_json::json!({"kind": "apps"})), ["Applications/Zqk.app"]);
    assert_eq!(ask(&mut helper, serde_json::json!({"kind": "folders"})), ["Applications/Zqk.app", "Documents/zqk folder"]);
    assert_eq!(ask(&mut helper, serde_json::json!({"ext": "pdf"})), ["Documents/zqk report.pdf"]);
    let downloads = root.join("Downloads").display().to_string();
    assert_eq!(ask(&mut helper, serde_json::json!({"folder": downloads, "kind": "documents"})), ["Downloads/zqk report.docx"]);
    let today = ask(&mut helper, serde_json::json!({"folder": downloads, "when": "today"}));
    assert_eq!(today, ["Downloads/zqk clip.mov", "Downloads/zqk report.docx", "Downloads/zqk tunes.mp3"]);
    assert_eq!(ask(&mut helper, serde_json::json!({"folder": downloads, "when": "month"})).len(), 3);
    // A typo keeps its filters.
    let (paths, _) = helper.ask(serde_json::json!({"query": "zqk-erp", "kind": "documents"}), &root);
    assert!(paths.is_empty(), "no name holds zqk-erp: {paths:?}");
    tree(&root, &["Documents/zqk-report.pdf", "Documents/zqk-report.png"]);
    let typo = Duration::from_secs(4);
    let start = Instant::now();
    loop {
        let (paths, _) = helper.ask(serde_json::json!({"query": "zqk-erp", "kind": "documents"}), &root);
        if !paths.is_empty() {
            assert_eq!(paths, ["Documents/zqk-report.pdf"]);
            break;
        }
        assert!(start.elapsed() < typo, "zqk-report.pdf not found by its typo");
        std::thread::sleep(Duration::from_millis(100));
    }
    helper.quit();
}

#[test]
fn says_where_a_file_came_from_and_filters_by_it() {
    let scratch = tempfile::tempdir().unwrap();
    let root = scratch.path().canonicalize().unwrap().join("home");
    tree(&root, &["Downloads/zqw-release.zip", "Downloads/zqw-photo.jpg", "Documents/zqw-notes.md"]);
    let mut where_froms = Vec::new();
    plist::Value::Array(vec!["https://github.com/example/repo/archive/main.zip".into(), "https://github.com/example/repo".into()])
        .to_writer_binary(&mut where_froms)
        .unwrap();
    // A browser writes both: the site wins. WhatsApp writes only the quarantine.
    xattr::set(root.join("Downloads/zqw-release.zip"), "com.apple.metadata:kMDItemWhereFroms", &where_froms).unwrap();
    xattr::set(root.join("Downloads/zqw-release.zip"), "com.apple.quarantine", b"0081;6704f1c2;Chrome;").unwrap();
    xattr::set(root.join("Downloads/zqw-photo.jpg"), "com.apple.quarantine", b"0083;6704f1c2;WhatsApp;F3A1").unwrap();
    let (mut helper, _) = Helper::start(&root, &scratch.path().join("files.cache"));

    writeln!(helper.stdin, "{}", serde_json::json!({"id": 1, "query": "zqw"})).unwrap();
    let answer = helper.line();
    let from = |name: &str| answer["files"].as_array().unwrap().iter().find(|f| f["path"].as_str().unwrap().ends_with(name)).unwrap()["from"].clone();
    assert_eq!(from("zqw-release.zip"), "github.com");
    assert_eq!(from("zqw-photo.jpg"), "WhatsApp");
    assert_eq!(from("zqw-notes.md"), serde_json::Value::Null, "no source: the key is left out");

    let (paths, _) = helper.ask(serde_json::json!({"query": "zqw", "from": "whatsapp"}), &root);
    assert_eq!(paths, ["Downloads/zqw-photo.jpg"]);
    let (paths, _) = helper.ask(serde_json::json!({"query": "zqw", "from": "GitHub"}), &root);
    assert_eq!(paths, ["Downloads/zqw-release.zip"]);
    // The site replaces the app: Chrome is not asked for.
    let (paths, _) = helper.ask(serde_json::json!({"query": "zqw", "from": "chrome"}), &root);
    assert!(paths.is_empty(), "{paths:?}");
    helper.quit();
}

#[test]
fn from_keeps_its_matches_past_the_limit() {
    let scratch = tempfile::tempdir().unwrap();
    let root = scratch.path().canonicalize().unwrap();
    std::fs::create_dir_all(root.join("a")).unwrap();
    for i in 0..30 {
        std::fs::write(root.join(format!("a/zqv-{i}.txt")), b"x").unwrap();
    }
    // Ranked last (deepest, longest path), yet the only WhatsApp file: the filter runs before the 20-file limit.
    std::fs::create_dir_all(root.join("a/b/c/d")).unwrap();
    let late = root.join("a/b/c/d/zqv-from-whatsapp-photo.jpg");
    std::fs::write(&late, b"x").unwrap();
    xattr::set(&late, "com.apple.quarantine", b"0083;6704f1c2;WhatsApp;").unwrap();
    let (mut helper, _) = Helper::start(&root, &root.join("files.cache"));
    assert_eq!(helper.paths("zqv").len(), 20);
    let (paths, _) = helper.ask(serde_json::json!({"query": "zqv", "from": "whatsapp"}), &root);
    assert_eq!(paths, ["a/b/c/d/zqv-from-whatsapp-photo.jpg"]);
    helper.quit();
}

#[test]
fn finds_identical_files_and_answers_searches_meanwhile() {
    let scratch = tempfile::tempdir().unwrap();
    let root = scratch.path().canonicalize().unwrap().join("home");
    // Two identical 2 MB files and one of the same size that differs in its last byte (check 4); an identical pair
    // under 1 KB, a hidden copy, a copy inside an app and copies in a git working tree are left out.
    let two_mb = vec![9u8; 2_000_000];
    let mut other = two_mb.clone();
    *other.last_mut().unwrap() = 1;
    for (file, bytes) in [("Downloads/zqd-video.mov", &two_mb), ("Documents/old/zqd-video copy.mov", &two_mb),
                          ("Documents/zqd-other.mov", &other), (".cache/zqd-video.mov", &two_mb),
                          ("Applications/Zqd.app/Contents/zqd-video.mov", &two_mb), ("code/app/assets/zqd-video.mov", &two_mb),
                          ("code/app/zqd-video.mov", &two_mb), ("code/app/.git/HEAD", &b"ref: refs/heads/main\n".to_vec())] {
        std::fs::create_dir_all(root.join(file).parent().unwrap()).unwrap();
        std::fs::write(root.join(file), bytes).unwrap();
    }
    tree(&root, &["Documents/zqd-tiny.txt", "Downloads/zqd-tiny.txt"]);
    let (mut helper, _) = Helper::start_with(&root, &scratch.path().join("files.cache"), &["--ignore", ""]);

    writeln!(helper.stdin, "{}", serde_json::json!({"id": 5, "dupes": true})).unwrap();
    // A search sent after the scan is still answered, the scan's answer arriving before or after it.
    writeln!(helper.stdin, "{}", serde_json::json!({"id": 6, "query": "zqd-other"})).unwrap();
    let (mut scan, mut search) = (None, None);
    while scan.is_none() || search.is_none() {
        let line = helper.line();
        if line.get("dupes").is_some() { scan = Some(line) } else { search = Some(line) }
    }
    let (scan, search) = (scan.unwrap(), search.unwrap());
    assert_eq!(search["id"], 6);
    assert_eq!(search["files"].as_array().unwrap().len(), 1);
    assert_eq!(scan["id"], 5);
    assert_eq!(scan["more"], 0);
    let groups = scan["dupes"].as_array().unwrap();
    assert_eq!(groups.len(), 1, "{groups:?}");
    assert_eq!(groups[0]["size"], 2_000_000);
    let mut paths: Vec<&str> = groups[0]["files"].as_array().unwrap().iter()
        .map(|f| f["path"].as_str().unwrap().strip_prefix(root.to_str().unwrap()).unwrap()).collect();
    paths.sort();
    assert_eq!(paths, ["/Documents/old/zqd-video copy.mov", "/Downloads/zqd-video.mov"]);
    assert!(groups[0]["files"][0]["modified"].as_u64().is_some());

    // Once one copy is gone, the next scan finds nothing.
    std::fs::rename(root.join("Documents/old/zqd-video copy.mov"), scratch.path().join("trashed.mov")).unwrap();
    writeln!(helper.stdin, "{}", serde_json::json!({"id": 7, "dupes": true})).unwrap();
    let again = helper.line();
    assert_eq!((again["id"].clone(), again["dupes"].as_array().unwrap().len()), (serde_json::json!(7), 0));
    helper.quit();
}
