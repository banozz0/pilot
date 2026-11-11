import json
import time
import unittest

from harness import ExtensionTestCase

LINK = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
# A yt-dlp that downloads nothing: it writes "Clip.<ext>" into its -P folder, prints one progress line and names the file
# where --print-to-file asks, as the real one does after its move.
YT_DLP = r'''
folder=""; saved=""; ext=mp4
while [ $# -gt 0 ]; do
  case "$1" in
    -P) folder="$2"; shift;;
    after_move:filepath) saved="$2"; shift;;
    --audio-format) ext="$2"; shift;;
  esac
  shift
done
echo "PILOT 500 1000 NA 100 5 18"
printf 'clip' > "$folder/Clip.$ext"
printf '%s\n' "$folder/Clip.$ext" > "$saved"
'''


class VideoDownloaderPageTests(ExtensionTestCase):
    """The page does its job (Sven, 2026-10-31): paste a link, click a format, the progress, then the saved file with
    Reveal in Finder. yt-dlp and ffmpeg are shims, so nothing downloads."""
    EXTENSION = "video-downloader"

    def setUp(self):
        super().setUp()
        self.box.shim("yt-dlp", YT_DLP)
        self.box.shim("ffmpeg")
        self.box.shim("open")
        self.box.shim("pbpaste", "exit 0")

    def box_of(self, blocks):
        self.assertEqual(blocks[0]["type"], "section")
        box = blocks[0]["blocks"][0]
        self.assertEqual(box["type"], "input")
        return box

    def test_the_box_offers_every_format_the_last_one_used_first(self):
        blocks = self.page()
        self.assertEqual(len(blocks), 1)  # nothing sends Sven to Hyper+Space or the menu bar (2026-10-31)
        box = self.box_of(blocks)
        self.assertEqual(box["action"]["context"], {"format": "best"})
        self.assertEqual([a["context"]["format"] for a in box["actions"]], ["720", "m4a", "mp3"])
        self.assertEqual({a["command"] for a in [box["action"]] + box["actions"]}, {"download"})

        (self.box.data / "last.json").write_text(json.dumps({"format": "mp3"}))
        box = self.box_of(self.page())
        self.assertEqual(box["action"]["title"], "Audio · MP3")
        self.assertEqual([a["context"]["format"] for a in box["actions"]], ["best", "720", "m4a"])

    def test_a_pasted_link_downloads_in_the_format_clicked_and_the_page_shows_the_file(self):
        started = self.run_ext("download", context={"format": "720"}, input=LINK)
        self.assertEqual(started.of_type("hud")[0]["text"], "Downloading youtube.com/watch?v=dQw4w9WgXcQ")
        job = {}
        deadline = time.time() + 10
        while time.time() < deadline and job.get("status") not in ("saved", "failed"):
            time.sleep(0.1)
            try:
                job = json.loads((self.box.data / "job.json").read_text())
            except (OSError, ValueError):
                pass
        self.assertEqual(job.get("status"), "saved", job)
        self.assertEqual(job["format"], "720")
        saved = self.box.home / "Downloads" / "Clip.mp4"
        self.assertTrue(saved.is_file())

        blocks = self.page()
        self.box_of(blocks)  # the box stays, for the next link
        self.assertEqual(blocks[1]["title"], "Saved")
        row = blocks[1]["items"][0]
        self.assertEqual(row["title"], "Clip.mp4")
        self.assertEqual(row["actions"][0]["command"], "reveal")

        self.run_ext("reveal", context=row["actions"][0]["context"])
        self.assertIn("open -R %s" % saved.resolve(), self.box.shim_calls())

    def test_a_failed_try_says_why_under_the_box(self):
        (self.box.data / "job.json").write_text(json.dumps({"status": "failed", "url": LINK, "format": "best",
                                                             "error": "Video unavailable"}))
        blocks = self.page()
        self.box_of(blocks)
        self.assertEqual(blocks[1], {"type": "markdown", "text": "The last download failed: Video unavailable"})


if __name__ == "__main__":
    unittest.main()
