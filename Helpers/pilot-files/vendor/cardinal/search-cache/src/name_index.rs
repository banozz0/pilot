use crate::{FileNodes, NAME_POOL, SlabIndex};
use itertools::Itertools;
use search_cancel::CancellationToken;
use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, time::Instant};
use thin_vec::ThinVec;
use tracing::info;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SortedSlabIndices {
    indices: ThinVec<SlabIndex>,
    /// Pilot: the name's `letters`, beside its nodes so a typo search rules most names out without reading them. Not
    /// saved: set again when the index loads (`construct_name_pool`).
    #[serde(skip)]
    letters: u64,
}

/// Pilot: one bit per letter or digit, either case, the rest sharing one. The helper's typo search (pilot-files
/// typo.rs) skips a name lacking more of a word's bits than the word's edits.
pub const LETTER_BITS: [u64; 256] = {
    let mut bits = [1 << 63; 256];
    let mut i = 0;
    while i < 26 {
        bits[b'a' as usize + i] = 1 << i;
        bits[b'A' as usize + i] = 1 << i;
        i += 1;
    }
    while i < 36 {
        bits[b'0' as usize + i - 26] = 1 << i;
        i += 1;
    }
    bits
};

/// Pilot: the `LETTER_BITS` of every byte in `text`.
pub fn letters(text: &[u8]) -> u64 {
    text.iter().fold(0, |m, &b| m | LETTER_BITS[b as usize])
}

impl SortedSlabIndices {
    pub fn new(index: SlabIndex, name: &str) -> Self {
        Self {
            indices: ThinVec::from_iter([index]),
            letters: letters(name.as_bytes()),
        }
    }

    pub fn len(&self) -> usize {
        self.indices.len()
    }

    pub fn is_empty(&self) -> bool {
        self.indices.is_empty()
    }

    pub fn iter(&self) -> impl Iterator<Item = &SlabIndex> {
        self.indices.iter()
    }

    pub fn insert(&mut self, index: SlabIndex, slab: &FileNodes) {
        let Some(target_path) = slab.node_path(index) else {
            return;
        };
        if let Err(pos) = self.indices.binary_search_by(|existing| {
            slab.node_path(*existing)
                .expect("node in name index must resolve to a path")
                .cmp(&target_path)
        }) {
            self.indices.insert(pos, index);
        }
    }

    /// # Safety
    ///
    /// The index must be inserted with it's full path ordered.
    pub unsafe fn insert_ordered(&mut self, index: SlabIndex) {
        self.indices.push(index);
    }

    pub fn remove(&mut self, index: SlabIndex) -> bool {
        if let Some(pos) = self.indices.iter().position(|&existing| existing == index) {
            self.indices.remove(pos);
            true
        } else {
            false
        }
    }
}

#[derive(Clone, Default)]
pub struct NameIndex {
    map: BTreeMap<&'static str, SortedSlabIndices>,
}

impl NameIndex {
    pub fn len(&self) -> usize {
        self.map.len()
    }

    pub fn is_empty(&self) -> bool {
        self.map.is_empty()
    }

    pub fn all_indices(&self, cancellation_token: CancellationToken) -> Option<Vec<SlabIndex>> {
        self.map
            .values()
            .flat_map(|indices| indices.iter().copied())
            .enumerate()
            .map(|(i, index)| {
                cancellation_token
                    .is_cancelled_sparse(i)
                    .map(|()| index)
                    .ok_or(())
            })
            .try_collect()
            .ok()
    }

    /// Pilot: the nodes of every name `keep` takes, in one pass over the names (the helper's typo search); a name whose
    /// `letters` `may` refuses is never read. The names are split by their first byte and the parts walked in parallel.
    pub fn indices_where(
        &self,
        may: impl Fn(u64) -> bool + Sync,
        keep: impl Fn(&str) -> bool + Sync,
        cancel: CancellationToken,
    ) -> Option<Vec<SlabIndex>> {
        use rayon::prelude::*;
        use std::ops::Bound::{Excluded, Included, Unbounded};
        const SPLITS: &[&str] = &[
            ".", "0", "A", "D", "G", "J", "M", "P", "S", "V", "_", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "l",
            "m", "n", "o", "p", "r", "s", "t", "u", "w", "\u{80}",
        ];
        let parts: Vec<(std::ops::Bound<&str>, std::ops::Bound<&str>)> = std::iter::once(Unbounded)
            .chain(SPLITS.iter().map(|s| Included(*s)))
            .zip(SPLITS.iter().map(|s| Excluded(*s)).chain(std::iter::once(Unbounded)))
            .collect();
        let found: Option<Vec<Vec<SlabIndex>>> = parts
            .into_par_iter()
            .map(|bounds| {
                let mut found = Vec::new();
                for (i, (name, indices)) in self.map.range::<str, _>(bounds).enumerate() {
                    cancel.is_cancelled_sparse(i)?;
                    if may(indices.letters) && keep(name) {
                        found.extend(indices.iter().copied());
                    }
                }
                Some(found)
            })
            .collect();
        Some(found?.concat())
    }

    pub fn get(&self, name: &str) -> Option<&SortedSlabIndices> {
        self.map.get(name)
    }

    pub fn get_mut(&mut self, name: &str) -> Option<&mut SortedSlabIndices> {
        self.map.get_mut(name)
    }

    /// # Safety
    ///
    /// The index must be inserted with it's full path ordered.
    pub unsafe fn add_index_ordered(&mut self, name: &str, index: SlabIndex) {
        if let Some(existing) = self.map.get_mut(name) {
            unsafe {
                existing.insert_ordered(index);
            }
        } else {
            let interned = NAME_POOL.push(name);
            self.map.insert(interned, SortedSlabIndices::new(index, name));
        }
    }

    pub fn add_index(&mut self, name: &str, index: SlabIndex, slab: &FileNodes) {
        if let Some(existing) = self.map.get_mut(name) {
            existing.insert(index, slab);
        } else {
            let interned = NAME_POOL.push(name);
            self.map.insert(interned, SortedSlabIndices::new(index, name));
        }
    }

    pub fn remove_index(&mut self, name: &str, index: SlabIndex) -> bool {
        let Some(indices) = self.map.get_mut(name) else {
            return false;
        };
        let removed = indices.remove(index);
        if indices.is_empty() {
            self.map.remove(name);
        }
        removed
    }

    pub fn remove(&mut self, name: &str) -> Option<SortedSlabIndices> {
        self.map.remove(name)
    }

    pub(crate) fn as_persistent(&self) -> BTreeMap<Box<str>, SortedSlabIndices> {
        self.map
            .iter()
            .map(|(name, indices)| ((*name).to_string().into_boxed_str(), indices.clone()))
            .collect()
    }

    pub fn into_persistent(self) -> BTreeMap<Box<str>, SortedSlabIndices> {
        self.map
            .into_iter()
            .map(|(name, indices)| (name.to_string().into_boxed_str(), indices))
            .collect()
    }

    pub fn construct_name_pool(data: BTreeMap<Box<str>, SortedSlabIndices>) -> Self {
        let name_pool_time = Instant::now();
        let mut map = BTreeMap::new();
        for (name, mut indices) in data {
            indices.letters = letters(name.as_bytes());
            let interned = NAME_POOL.push(&name);
            map.insert(interned, indices);
        }
        info!(
            "Name pool construction time: {:?}, count: {}",
            name_pool_time.elapsed(),
            NAME_POOL.len(),
        );
        Self { map }
    }
}
