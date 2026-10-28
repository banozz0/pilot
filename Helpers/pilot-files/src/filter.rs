//! The Files view's filters (N5, Sven 2026-10-09: "sooooo many files that no human should read"). A search line is
//! either the bare text, as before, or a JSON request carrying the filters, which become Cardinal terms after the typed
//! words: Cardinal narrows by name first and checks kind, folder and date only on those matches, so a filter costs no
//! extra pass over the index. What is hidden by default (dot names, bundle insides) is dropped here per search, not left
//! out of the index, so the Show hidden switch brings it back at once without a second walk.

use serde::Deserialize;
use std::path::Path;

/// One search. `id` comes back on the answer, so Pilot never takes an answer to an older filter for the newest one.
#[derive(Debug, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct Request {
    pub id: Option<u64>,
    pub query: String,
    /// folders, documents, images, video, audio, code, archives or apps.
    pub kind: Option<String>,
    /// One extension, typed as `kind:pdf`.
    pub ext: Option<String>,
    /// Only files under this folder (an absolute path).
    pub folder: Option<String>,
    /// today, week or month: edited since its start.
    pub when: Option<String>,
    /// Dot names and bundle insides too.
    pub hidden: bool,
    /// Only files whose source (source.rs: the site, else the app) holds this, typed as `from:whatsapp`.
    pub from: Option<String>,
}

impl Request {
    /// A line from Pilot: a JSON request, or any other line as the bare search with no filters.
    pub fn parse(line: &str) -> Request {
        if line.starts_with('{')
            && let Ok(request) = serde_json::from_str(line)
        {
            return request;
        }
        Request { query: line.to_string(), ..Request::default() }
    }

    /// The filters as Cardinal terms, each after a space; empty without filters. An unknown kind, an extension that is
    /// not a plain word or a folder holding a quote is dropped rather than read as Cardinal syntax.
    pub fn terms(&self, root: &Path) -> String {
        let mut terms = String::new();
        if let Some(kind) = self.kind.as_deref().and_then(kind_terms) {
            terms += " ";
            terms += kind;
        }
        if let Some(ext) = self.ext.as_deref().filter(|e| !e.is_empty() && e.chars().all(char::is_alphanumeric)) {
            terms += &format!(" ext:{ext}");
        }
        if let Some(folder) = self.folder.as_deref().filter(|f| !f.contains('"') && Path::new(f) != root) {
            terms += &format!(r#" infolder:"{folder}""#);
        }
        if let Some(when) = self.when.as_deref().and_then(when_term) {
            terms += " ";
            terms += when;
        }
        terms
    }
}

/// A kind as Cardinal's filters: its type groups, documents with slides and sheets, apps as the .app folders.
fn kind_terms(kind: &str) -> Option<&'static str> {
    Some(match kind {
        "folders" => "folder:",
        "documents" => "ext:txt;md;rst;doc;docx;rtf;odt;pdf;pages;rtfd;ppt;pptx;key;odp;xls;xlsx;csv;numbers;ods",
        "images" => "type:picture",
        "video" => "type:video",
        "audio" => "type:audio",
        "code" => "type:code",
        "archives" => "type:archive",
        "apps" => "folder: *.app",
        _ => return None,
    })
}

fn when_term(when: &str) -> Option<&'static str> {
    Some(match when {
        "today" => "dm:today",
        "week" => "dm:thisweek",
        "month" => "dm:thismonth",
        _ => return None,
    })
}

/// A package Finder shows as one file; what is inside it is not a result.
pub const BUNDLES: &[&str] = &[".app", ".framework", ".bundle", ".photoslibrary", ".xcodeproj", ".xcworkspace", ".plugin", ".kext"];
/// Another tool's thousands of files that the never-index list may let through: kept out of sight until asked.
const HIDDEN_FOLDERS: &[&str] = &["site-packages", "Pods", "__pycache__", "node_modules", "DerivedData", "venv"];

/// Hidden unless Show hidden is on: a dot name or anything under a dot folder, anything inside a bundle (the bundle
/// itself stays), and what sits under another tool's folder. `rel` is the path under the watched root.
pub fn hidden(rel: &Path) -> bool {
    let name = rel.file_name().and_then(|n| n.to_str()).unwrap_or("");
    name.starts_with('.')
        || rel.parent().into_iter().flat_map(Path::components).any(|folder| {
            let folder = folder.as_os_str().to_str().unwrap_or("");
            folder.starts_with('.') || HIDDEN_FOLDERS.contains(&folder) || BUNDLES.iter().any(|b| folder.ends_with(b))
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(json: &str) -> Request {
        Request::parse(json)
    }

    #[test]
    fn a_bare_line_is_the_search_with_nothing_hidden_shown() {
        assert_eq!(Request::parse("budget rep"), Request { query: "budget rep".into(), ..Request::default() });
        assert_eq!(Request::parse("{not json").query, "{not json");
        let r = request(r#"{"id":4,"query":"budget","kind":"images","hidden":true,"from":"whatsapp"}"#);
        assert_eq!((r.id, r.query.as_str(), r.kind.as_deref(), r.hidden), (Some(4), "budget", Some("images"), true));
        assert_eq!(r.from.as_deref(), Some("whatsapp"));
    }

    #[test]
    fn filters_become_cardinal_terms() {
        let root = Path::new("/Users/ada");
        let r = request(r#"{"query":"x","kind":"documents","folder":"/Users/ada/Downloads","when":"week"}"#);
        let terms = r.terms(root);
        assert!(terms.starts_with(" ext:txt;md;"), "{terms}");
        assert!(terms.ends_with(r#" infolder:"/Users/ada/Downloads" dm:thisweek"#), "{terms}");
        assert_eq!(request(r#"{"query":"x","kind":"apps"}"#).terms(root), " folder: *.app");
        assert_eq!(request(r#"{"query":"x","ext":"pdf","when":"today"}"#).terms(root), " ext:pdf dm:today");
        // Home is the root: no folder term. Junk is dropped, never passed on as syntax.
        assert_eq!(request(r#"{"query":"x","folder":"/Users/ada"}"#).terms(root), "");
        assert_eq!(request(r#"{"query":"x","kind":"bogus","ext":"p|df","folder":"/a\"b","when":"year"}"#).terms(root), "");
        assert_eq!(Request::parse("x").terms(root), "");
    }

    #[test]
    fn hides_dot_names_bundle_insides_and_tool_folders() {
        for path in [".zshrc", ".config/aerospace/aerospace.toml", "code/app/.env", "Applications/Notes.app/Contents/Info.plist",
                     "Pictures/Photos Library.photoslibrary/database/x.db", "code/py/venv/lib/x.py",
                     "code/py/lib/site-packages/requests/api.py", "code/ios/Pods/Alamofire/x.swift"] {
            assert!(hidden(Path::new(path)), "{path}");
        }
        for path in ["Documents/budget.xlsx", "Applications/Notes.app", "code/app/src/main.rs",
                     "Library/Mobile Documents/com~apple~CloudDocs/notes.md"] {
            assert!(!hidden(Path::new(path)), "{path}");
        }
    }
}
