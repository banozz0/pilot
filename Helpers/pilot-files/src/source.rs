//! Where a file came from (Homy-style Files, T2): the site a browser saved it from, else the app that saved it. Read
//! per hit from the two attributes macOS writes on a download, so nothing is added to the index. On 2026-10-12, 7 of
//! 25 files in ~/Downloads had a site (Chrome, Zen), 15 only an app (WhatsApp) and 3 neither.

use std::{io::Cursor, path::Path};

/// The URLs a browser saved the file from, the page's first (a binary plist array of strings).
const WHERE_FROMS: &str = "com.apple.metadata:kMDItemWhereFroms";
/// `flags;time;app;uuid`, written by any app that saves a file from the net.
const QUARANTINE: &str = "com.apple.quarantine";

/// The host of the first WhereFroms URL, else the quarantine's app name, else nothing.
pub fn read(path: &Path) -> Option<String> {
    xattr::get(path, WHERE_FROMS).ok().flatten().and_then(|raw| site(&raw))
        .or_else(|| xattr::get(path, QUARANTINE).ok().flatten().and_then(|raw| app(&raw)))
}

/// Whether `from` (typed as `from:whatsapp`, lowercased by the caller) is in the file's source, ignoring case.
pub fn matches(source: Option<&str>, from: &str) -> bool {
    source.is_some_and(|s| s.to_lowercase().contains(from))
}

fn site(raw: &[u8]) -> Option<String> {
    let plist::Value::Array(urls) = plist::Value::from_reader(Cursor::new(raw)).ok()? else { return None };
    host(urls.first()?.as_string()?)
}

/// `https://user@www.github.com:443/x?y` → `github.com`; a value with no scheme (a bare note some apps write) is none.
fn host(url: &str) -> Option<String> {
    let rest = url.split_once("://")?.1;
    let authority = rest.split(['/', '?', '#']).next()?;
    let host = authority.rsplit('@').next()?.split(':').next()?.to_lowercase();
    let host = host.strip_prefix("www.").unwrap_or(&host);
    (!host.is_empty()).then(|| host.to_string())
}

fn app(raw: &[u8]) -> Option<String> {
    let app = String::from_utf8_lossy(raw).split(';').nth(2)?.trim().to_string();
    (!app.is_empty()).then_some(app)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_of_a_url() {
        assert_eq!(host("https://github.com/example/repo/archive/main.zip").as_deref(), Some("github.com"));
        assert_eq!(host("https://user@WWW.Example.org:8443?x=1").as_deref(), Some("example.org"));
        assert_eq!(host("mail.google.com"), None);
        assert_eq!(host("https:///x"), None);
    }

    #[test]
    fn app_of_a_quarantine() {
        assert_eq!(app(b"0083;6704f1c2;WhatsApp;F3A1").as_deref(), Some("WhatsApp"));
        assert_eq!(app(b"0081;6704f1c2;;"), None);
        assert_eq!(app(b"0081"), None);
    }

    #[test]
    fn site_of_a_where_froms_plist() {
        let mut raw = Vec::new();
        let urls = plist::Value::Array(vec!["https://github.com/x.zip".into(), "https://github.com/x".into()]);
        urls.to_writer_binary(&mut raw).unwrap();
        assert_eq!(site(&raw).as_deref(), Some("github.com"));
        assert_eq!(site(b"junk"), None);
    }

    #[test]
    fn from_matches_either_ignoring_case() {
        assert!(matches(Some("WhatsApp"), "whatsapp"));
        assert!(matches(Some("GitHub.com"), "github"));
        assert!(!matches(Some("github.com"), "whatsapp"));
        assert!(!matches(None, "whatsapp"));
    }
}
