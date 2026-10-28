//! Identical files (Homy-style Files, T5): the Files page's Duplicates tab asks on demand, never in the background.
//! Sizes come from the index the helper already holds: each file's size is read once (Cardinal keeps it on the node,
//! so the next scan reads none again), in steps between searches so the menu never waits on a scan. Only files that
//! share a size are read: the first 64 KB, then the whole file, each as SHA-256, on a thread of their own while
//! searches go on. Files under 1 KB, iCloud files not on this Mac (reading one would download it), what the Files view
//! hides (dot names, bundle insides, another tool's folders) and the never-index list are skipped, and so is every
//! file in a git working tree (a folder under the root holding `.git`): a repo's files and its vendored copies are its
//! own, never offered for the Trash. Package insides macOS knows of (an .rtfd, an iMovie library) are Pilot's to drop,
//! as only Launch Services knows them. A second name for one file (a hard link) frees nothing, so it is left out too.
//!
//! Request: {"id":N,"dupes":true}. Answer: {"id":N,"dupes":[{"size":N,"files":[{"path":"…","modified":N|null}]}],
//! "more":N,"ms":N}, the groups that free the most first, at most GROUPS of them; `more` counts the rest.

use crate::{Hit, filter};
use search_cache::{SearchCache, SlabIndex};
use search_cancel::CancellationToken;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    fs::File,
    io::Read,
    os::macos::fs::MetadataExt,
    path::{Path, PathBuf},
    time::{Instant, UNIX_EPOCH},
};

/// Smaller files free next to nothing.
const SMALLEST: u64 = 1024;
/// Read first; only files whose first bytes match are read whole.
const HEAD: usize = 64 * 1024;
/// Files sized per step, between which searches and file changes are served.
const STEP: usize = 4096;
/// Groups per answer, the ones that free the most.
const GROUPS: usize = 200;
/// `SF_DATALESS`: an iCloud file whose contents are not on this Mac.
const DATALESS: u32 = 0x4000_0000;

/// A stdin line asking for duplicates; any other line is a search.
#[derive(Deserialize)]
pub struct Scan {
    pub id: Option<u64>,
    dupes: bool,
}

impl Scan {
    pub fn parse(line: &str) -> Option<Scan> {
        // Every search passes here: only a line naming dupes is decoded.
        if !line.starts_with('{') || !line.contains(r#""dupes""#) {
            return None;
        }
        serde_json::from_str::<Scan>(line).ok().filter(|scan| scan.dupes)
    }
}

#[derive(Serialize)]
struct Answer {
    #[serde(skip_serializing_if = "Option::is_none")]
    id: Option<u64>,
    dupes: Vec<Group>,
    more: usize,
    ms: u128,
}

#[derive(Serialize)]
struct Group {
    size: u64,
    files: Vec<Hit>,
}

/// The sizing pass over the index, a step at a time. A newer scan replaces it and stops its reading (Cardinal's scan
/// token, which nothing else in the helper takes).
pub struct Sizing {
    id: Option<u64>,
    started: Instant,
    cancel: CancellationToken,
    nodes: Vec<SlabIndex>,
    at: usize,
    sized: Vec<(u64, SlabIndex)>,
}

impl Sizing {
    pub fn start(cache: &SearchCache, scan: Scan) -> Sizing {
        let nodes = cache.search_empty(CancellationToken::noop()).unwrap_or_default();
        Sizing { id: scan.id, started: Instant::now(), cancel: CancellationToken::new_scan(), nodes, at: 0, sized: Vec::new() }
    }

    /// Sizes the next STEP files; true once every file is sized and the reading has been handed to its thread.
    pub fn step(&mut self, cache: &mut SearchCache, root: &Path) -> bool {
        let end = (self.at + STEP).min(self.nodes.len());
        let chunk = &self.nodes[self.at..end];
        for (node, &index) in cache.expand_file_nodes(chunk).into_iter().zip(chunk) {
            // Folders size as -1; a node gone since the list was taken has no path.
            let Some(size) = node.metadata.as_ref().map(|m| m.size()).and_then(|s| u64::try_from(s).ok()) else { continue };
            let rel = node.path.strip_prefix(root).unwrap_or(&node.path);
            if size >= SMALLEST && !node.path.as_os_str().is_empty() && !filter::hidden(rel) {
                self.sized.push((size, index));
            }
        }
        self.at = end;
        if self.at < self.nodes.len() {
            return false;
        }
        let candidates = same_size(std::mem::take(&mut self.sized), cache);
        let (id, started, cancel, root) = (self.id, self.started, self.cancel, root.to_path_buf());
        std::thread::spawn(move || {
            if let Some((dupes, more)) = identical(candidates, &root, cancel) {
                crate::send(&Answer { id, dupes, more, ms: started.elapsed().as_millis() });
            }
        });
        true
    }
}

/// Files sharing a size with another, as paths, by size.
fn same_size(mut sized: Vec<(u64, SlabIndex)>, cache: &SearchCache) -> Vec<(u64, Vec<PathBuf>)> {
    sized.sort_unstable_by_key(|&(size, _)| size);
    sized
        .chunk_by(|a, b| a.0 == b.0)
        .filter(|run| run.len() > 1)
        .map(|run| (run[0].0, run.iter().filter_map(|&(_, index)| cache.node_path(index)).collect()))
        .collect()
}

/// The groups of identical files, freeing the most first, and how many more were left out; None when a newer scan
/// replaced this one.
fn identical(candidates: Vec<(u64, Vec<PathBuf>)>, root: &Path, cancel: CancellationToken) -> Option<(Vec<Group>, usize)> {
    let (mut groups, mut repos) = (Vec::new(), GitTrees::default());
    for (size, mut paths) in candidates {
        cancel.is_cancelled()?;
        paths.retain(|path| !repos.holds(path, root));
        let copies = readable(size, paths);
        for heads in alike(copies, |path| digest(path, HEAD)) {
            // A whole-file pass can be long: checked before each.
            cancel.is_cancelled()?;
            let wholes = if size as usize <= HEAD { vec![heads] } else { alike(heads, |path| digest(path, usize::MAX)) };
            for files in wholes {
                groups.push(Group { size, files: files.into_iter().map(|(path, modified)| Hit { path, modified, from: None }).collect() });
            }
        }
    }
    groups.sort_by_key(|g| std::cmp::Reverse(g.size * (g.files.len() as u64 - 1)));
    let more = groups.len().saturating_sub(GROUPS);
    groups.truncate(GROUPS);
    Some((groups, more))
}

/// Which folders are in a git working tree, each asked of the disk once a scan.
#[derive(Default)]
struct GitTrees(HashMap<PathBuf, bool>);

impl GitTrees {
    /// Whether a folder between the root (not included: a home kept in git is still searched) and the file holds
    /// `.git`, a folder or a worktree's file.
    fn holds(&mut self, path: &Path, root: &Path) -> bool {
        let Some(folder) = path.parent().filter(|f| f.starts_with(root) && *f != root) else { return false };
        if let Some(&known) = self.0.get(folder) {
            return known;
        }
        let held = folder.join(".git").symlink_metadata().is_ok() || self.holds(folder, root);
        self.0.insert(folder.to_path_buf(), held);
        held
    }
}

/// The files still `size` bytes, plain and on this Mac, one name per file; each with its modified time.
fn readable(size: u64, paths: Vec<PathBuf>) -> Vec<(String, Option<u64>)> {
    let mut seen = HashSet::new();
    paths
        .into_iter()
        .filter_map(|path| {
            let meta = std::fs::symlink_metadata(&path).ok()?;
            let plain = meta.is_file() && meta.len() == size && meta.st_flags() & DATALESS == 0;
            (plain && seen.insert((meta.st_dev(), meta.st_ino()))).then(|| {
                let modified = meta.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs());
                (path.to_string_lossy().into_owned(), modified)
            })
        })
        .collect()
}

/// The files split by `digest`, each part of two or more; a file that cannot be read is left out.
fn alike(files: Vec<(String, Option<u64>)>, digest: impl Fn(&str) -> Option<[u8; 32]>) -> Vec<Vec<(String, Option<u64>)>> {
    if files.len() < 2 {
        return vec![];
    }
    let mut by: HashMap<[u8; 32], Vec<(String, Option<u64>)>> = HashMap::new();
    for file in files {
        if let Some(hash) = digest(&file.0) {
            by.entry(hash).or_default().push(file);
        }
    }
    by.into_values().filter(|part| part.len() > 1).collect()
}

/// SHA-256 of the file's first `limit` bytes (all of it for `usize::MAX`), read 64 KB at a time.
fn digest(path: &str, limit: usize) -> Option<[u8; 32]> {
    let mut file = File::open(path).ok()?;
    let (mut hasher, mut buffer, mut left) = (Sha256::new(), vec![0; HEAD], limit);
    while left > 0 {
        let read = file.read(&mut buffer[..HEAD.min(left)]).ok()?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
        left -= read;
    }
    Some(hasher.finalize().into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_dupes_line_is_a_scan() {
        assert_eq!(Scan::parse(r#"{"id":7,"dupes":true}"#).map(|s| s.id), Some(Some(7)));
        assert!(Scan::parse(r#"{"id":7,"dupes":false}"#).is_none());
        assert!(Scan::parse(r#"{"id":7,"query":"dupes"}"#).is_none());
        assert!(Scan::parse("dupes").is_none());
    }

    #[test]
    fn same_head_different_tail_is_no_duplicate() {
        let scratch = tempfile::tempdir().unwrap();
        let (a, b, c) = (scratch.path().join("a"), scratch.path().join("b"), scratch.path().join("c"));
        let mut bytes = vec![7u8; HEAD + 10];
        std::fs::write(&a, &bytes).unwrap();
        std::fs::write(&b, &bytes).unwrap();
        *bytes.last_mut().unwrap() = 8;
        std::fs::write(&c, &bytes).unwrap();
        // A hard link to `a` is the same file, not a copy.
        std::fs::hard_link(&a, scratch.path().join("a-link")).unwrap();
        let paths = vec![a.clone(), b.clone(), c, scratch.path().join("a-link")];
        let (groups, more) = identical(vec![(bytes.len() as u64, paths)], scratch.path(), CancellationToken::noop()).unwrap();
        assert_eq!(more, 0);
        assert_eq!(groups.len(), 1);
        let mut found: Vec<_> = groups[0].files.iter().map(|f| f.path.clone()).collect();
        found.sort();
        assert_eq!(found, [a.to_string_lossy(), b.to_string_lossy()]);
        let older = CancellationToken::new_scan();
        CancellationToken::new_scan();
        assert!(identical(vec![(1, vec![])], scratch.path(), older).is_none(), "a newer scan stops this one");
    }
}
