//! Which of Cardinal's matches the menu sees first. Cardinal returns every name that holds the query, unordered;
//! the menu shows 20, so the helper keeps the ones a person most likely meant: the name itself before a name that
//! merely holds the query, shallow before deep, and, when Show hidden lets them through (filter::hidden), nothing hidden
//! or from inside a hidden folder, a build folder or an app bundle unless nothing else matched. Pilot ranks the kept
//! rows again beside its apps and actions.

use crate::typo::Typos;
use std::path::Path;

/// Folders whose contents are noise for a launcher: generated, vendored or another tool's state. The never-index list
/// (main.rs, DEFAULT_IGNORE, or Pilot's own) keeps most out of the index; these are kept but pushed down.
const NOISE: &[&str] = &["target", "DerivedData", "__pycache__", "site-packages", "venv", "Pods", "vendor"];

/// Higher is better. `rel` is the path under the watched root, `words` the typed words, lowercased; each is scored
/// on the file name and the weakest sets the tier, since Cardinal already required every word to match. `typos` is the
/// typo search that found these (typo.rs): a word the name holds only within its edits ranks under one it holds as typed.
pub fn score(rel: &Path, words: &[String], typos: Option<&Typos>) -> i32 {
    let original = rel.file_name().map(|n| n.to_string_lossy()).unwrap_or_default();
    let name = original.to_lowercase();
    let stem = name.rsplit_once('.').map_or(name.as_str(), |(s, _)| s);
    // The typo's edits on the name as written: its capitals start words (FileIndex: "index").
    let tier = words.iter().map(|w| tier(&name, stem, w, typos.and_then(|t| t.edits(&original, w)))).min().unwrap_or(0);
    let (mut depth, mut buried) = (0, crate::filter::hidden(rel));
    for folder in rel.parent().into_iter().flat_map(Path::components) {
        depth += 1;
        buried |= NOISE.contains(&folder.as_os_str().to_str().unwrap_or(""));
    }
    tier - 10 * depth.min(10) - if buried { 500 } else { 0 }
}

/// The typed text as `score` takes it.
pub fn words(query: &str) -> Vec<String> {
    query.split_whitespace().map(str::to_lowercase).collect()
}

/// 1000 the whole name, 900 the name without its extension, 700 its start, 500 a word's start, 300 anywhere in
/// it, 250 within one typo and 200 within two (`edits`, typo.rs); 100 when the word matched a folder on the path rather
/// than the name.
fn tier(name: &str, stem: &str, word: &str, edits: Option<u32>) -> i32 {
    if let Some(k) = edits {
        300 - 50 * k as i32
    } else if name == word {
        1000
    } else if stem == word {
        900
    } else if name.starts_with(word) {
        700
    } else if name.match_indices(word).any(|(i, _)| !name[..i].ends_with(|c: char| c.is_alphanumeric())) {
        500
    } else if name.contains(word) {
        300
    } else {
        100
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(path: &str, query: &str) -> i32 {
        score(Path::new(path), &words(query), None)
    }

    #[test]
    fn the_name_itself_beats_a_name_holding_it() {
        assert!(s("Documents/budget.xlsx", "budget") > s("Documents/old-budget.xlsx", "budget"));
        assert!(s("Documents/budget", "budget") > s("Documents/budget.xlsx", "budget"));
        assert!(s("Documents/budget-2026.xlsx", "budget") > s("Documents/old-budget.xlsx", "budget"));
        assert!(s("Documents/old-budget.xlsx", "budget") > s("Documents/oldbudget.xlsx", "budget"));
    }

    #[test]
    fn shallow_beats_deep_and_noise_comes_last() {
        assert!(s("notes.md", "notes") > s("a/b/c/notes.md", "notes"));
        assert!(s("a/b/c/d/e/f/notes.md", "notes") > s("code/app/target/notes.md", "notes"));
        assert!(s("a/b/c/d/e/f/notes.md", "notes") > s(".cache/notes.md", "notes"));
        assert!(s("a/b/c/d/e/f/obsidian", "obsidian") > s(".obsidian", "obsidian"));
        assert!(s("a/b/c/d/e/f/notes.md", "notes") > s("Applications/Notes.app/Contents/notes.md", "notes"));
    }

    #[test]
    fn a_typo_ranks_under_the_word_as_typed() {
        let typos = Typos::parse("budget reprot").unwrap();
        let t = |path: &str| score(Path::new(path), &words("budget reprot"), Some(&typos));
        assert!(t("budget report.pdf") > t("a/budget report.pdf"));
        assert!(t("x/budget reprot.pdf") > t("x/budget report.pdf"));
        let typos = Typos::parse("fileindx.swift").unwrap();
        let t = |path: &str| score(Path::new(path), &words("fileindx.swift"), Some(&typos));
        assert!(t("a/b/c/FileIndex.swift") > t("a/FileKinds.swift"), "one edit before two");
        let typos = Typos::parse("indx").unwrap();
        assert_eq!(score(Path::new("FileIndex.swift"), &words("indx"), Some(&typos)), 250, "a capital starts the typo's word");
    }

    #[test]
    fn every_word_counts_and_a_folder_match_is_weakest() {
        assert!(s("Documents/budget report.pdf", "budget report") > s("Documents/budget/report.pdf", "budget report"));
        assert_eq!(s("x/Budget.PDF", "BUDGET"), s("x/budget.pdf", "budget"));
    }
}
