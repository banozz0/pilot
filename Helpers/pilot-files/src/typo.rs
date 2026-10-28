//! Typo search (spec file-search-v2 T1): a search that found nothing is tried once more, in one pass over the index's
//! names, forgiving a wrong, extra, missing or swapped letter in a word of four letters or more, two from eight
//! ("FileIndx" finds FileIndex.swift). The approach is fsearch's (Noah Dunnagan, MIT, github.com/noahdunnagan/fsearch):
//! a mask of the letters in a name rules most names out before any comparison, a typo match starts at a word's start
//! with its first letter kept unless two edits are allowed, and digits are never edited ("hat_18" is another file than
//! "hat_98"). The code is Pilot's own.

/// Edits a word of this many letters forgives: one from four, two from eight.
const ONE_EDIT: usize = 4;
const TWO_EDITS: usize = 8;

pub struct Typos {
    words: Vec<Word>,
}

struct Word {
    text: Vec<u8>,
    /// The word as typed, found in a name: built once for every name the search reads.
    finder: memchr::memmem::Finder<'static>,
    mask: u64,
    edits: u32,
}

impl Typos {
    /// None when no word is long enough to forgive a typo, or the search uses Cardinal's own syntax.
    pub fn parse(query: &str) -> Option<Typos> {
        let plain = query.chars().all(|c| c.is_alphanumeric() || c.is_whitespace() || "-_.".contains(c));
        let words: Vec<Word> = query
            .split_whitespace()
            .map(|w| {
                let text = w.to_lowercase().into_bytes();
                let edits = (text.len() >= ONE_EDIT) as u32 + (text.len() >= TWO_EDITS) as u32;
                Word { mask: search_cache::letters(&text), finder: memchr::memmem::Finder::new(&text).into_owned(), text, edits }
            })
            .collect();
        (plain && words.iter().any(|w| w.edits > 0)).then_some(Typos { words })
    }

    /// Whether a name with these letters (search_cache::letters) can match: most names are ruled out here, by the bits
    /// the index keeps beside them, before their text is read. An edit takes at most one of a word's bits away.
    pub fn may(&self, letters: u64) -> bool {
        self.words.iter().all(|w| (w.mask & !letters).count_ones() <= w.edits)
    }

    /// Every word is in the name, as typed or within its edits; `may` ruled out the rest already.
    pub fn matches(&self, name: &str) -> bool {
        let name = name.as_bytes();
        let mut folded = [0u8; 256];
        let Some(folded) = folded.get_mut(..name.len()) else { return false };
        for (f, &b) in folded.iter_mut().zip(name) {
            *f = b.to_ascii_lowercase();
        }
        self.words.iter().all(|w| w.finder.find(folded).is_some() || near(name, folded, w, w.edits))
    }

    /// The fewest edits the name holds a word within, None when it holds it as typed (or not at all): a typo match
    /// ranks under one as typed, and one edit over two.
    pub fn edits(&self, name: &str, word: &str) -> Option<u32> {
        let w = self.words.iter().find(|w| w.text == word.as_bytes())?;
        let folded = name.to_ascii_lowercase();
        if folded.contains(word) {
            return None;
        }
        (1..=w.edits).find(|&k| near(name.as_bytes(), folded.as_bytes(), w, k))
    }
}

/// The word within `k` edits at the start of a word in the name: the name's start, after a mark or a space, or a
/// capital after a small letter (FileIndex: "file", "index").
fn near(name: &[u8], folded: &[u8], w: &Word, k: u32) -> bool {
    k > 0
        && (0..folded.len()).any(|s| {
            let start = s == 0 || !name[s - 1].is_ascii_alphanumeric() || (name[s - 1].is_ascii_lowercase() && name[s].is_ascii_uppercase());
            start && (k > 1 || folded[s] == w.text[0]) && within(&folded[s..], &w.text, k)
        })
}

/// Whether `q` spells the start of `w` with at most `k` edits: a wrong, extra, missing or swapped letter.
fn within(w: &[u8], q: &[u8], k: u32) -> bool {
    let same = w.iter().zip(q).take_while(|(a, b)| a == b).count();
    let (w, q) = (&w[same..], &q[same..]);
    let Some(&first) = q.first() else { return true };
    if k == 0 || first.is_ascii_digit() || w.first().is_some_and(u8::is_ascii_digit) {
        return false;
    }
    let rest = &q[1..];
    (!w.is_empty() && within(&w[1..], rest, k - 1))
        || within(w, rest, k - 1)
        || (!w.is_empty() && within(&w[1..], q, k - 1))
        || (w.len() >= 2 && rest.first() == Some(&w[0]) && w[1] == first && within(&w[2..], &rest[1..], k - 1))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn finds(query: &str, name: &str) -> bool {
        let typos = Typos::parse(query).unwrap();
        typos.may(search_cache::letters(name.as_bytes())) && typos.matches(name)
    }

    #[test]
    fn a_wrong_extra_missing_or_swapped_letter() {
        assert!(finds("FileIndx", "FileIndex.swift"));
        assert!(finds("lean-budgts", "lean-budgets.json"));
        assert!(finds("kemap", "keymap.toml"));
        assert!(finds("keymapp", "keymap.toml"));
        assert!(finds("kyemap", "keymap.toml"));
        assert!(finds("kezmap", "keymap.toml"));
    }

    #[test]
    fn a_word_starts_anywhere_in_the_name() {
        assert!(finds("indx", "FileIndex.swift"));
        assert!(finds("budgte", "2026 budget.xlsx"));
        assert!(!finds("ndexx", "FileIndex.swift"), "a typo match starts at a word's start");
    }

    #[test]
    fn short_words_digits_and_first_letters_stay_exact() {
        assert!(Typos::parse("kem").is_none());
        assert!(Typos::parse("ke*map").is_none());
        assert!(!finds("hat_98x", "hat_18x.png"), "digits are never edited");
        assert!(!finds("xeymap", "keymap.toml"), "one edit keeps the first letter");
        assert!(finds("filexindxx", "FileIndex.swift"), "two edits from eight letters");
        assert!(!finds("fxlxindx", "FileIndex.swift"), "three edits is not a typo");
    }

    #[test]
    fn every_word_must_match() {
        assert!(finds("budget reprot", "budget report.pdf"));
        assert!(!finds("budget reprot", "budget.pdf"));
        let typos = Typos::parse("budget reprot").unwrap();
        assert_eq!(typos.edits("budget report.pdf", "reprot"), Some(1));
        assert_eq!(typos.edits("budget report.pdf", "budget"), None);
        let typos = Typos::parse("fileindx.swift").unwrap();
        assert_eq!(typos.edits("FileIndex.swift", "fileindx.swift"), Some(1));
        assert_eq!(typos.edits("FileKinds.swift", "fileindx.swift"), Some(2));
    }
}
