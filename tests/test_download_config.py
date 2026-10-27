import ast
import logging
import re
import sys
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from gallery_dl import config, extractor, job
from gallery_dl.extractor.common import Message
from gallery_dl.downloader.http import HttpDownloader
from gallery_dl.downloader.ytdl import YoutubeDLDownloader


# Load pure config helpers without starting Flask's scheduler/scan threads.
SOURCE = Path(__file__).resolve().parents[1] / "app.py"
TREE = ast.parse(SOURCE.read_text())
HELPERS = {
    "STREAM_SLEEP_REQUESTS": 3.0,
    "STREAM_VIDEO_SLEEP": 5.0,
    "STREAM_BROWSER_UA": "test-browser",
    "STREAM_PACING_CONFIG_FILE": "/config/gallery-dl.artillery.conf",
    "os": __import__("os"),
    "sys": sys,
    "__file__": str(SOURCE),
    "logging": logging,
    "re": re,
}
for node in TREE.body:
    if isinstance(node, ast.FunctionDef) and node.name in {
        "_stream_pacing_config", "_append_stream_pacing_config",
        "_run_gallery_dl", "_download_process_args",
    }:
        exec(compile(ast.Module(body=[node], type_ignores=[]), str(SOURCE), "exec"), HELPERS)


class DownloadConfigTests(unittest.TestCase):
    def setUp(self):
        self.saved_config = config._config.copy()
        config.clear()
        self.managed = HELPERS["_stream_pacing_config"]()
        config._config.update(self.managed)

    def tearDown(self):
        config.clear()
        config._config.update(self.saved_config)

    def test_delay_applies_before_extraction(self):
        hotleak = self.managed["extractor"]["hotleak"]
        self.assertEqual(hotleak["sleep"], "5.0-15.0")
        # Transfer/fragment retries remain enabled inside yt-dlp.
        self.assertEqual(hotleak["ytdl"]["raw-options"]["fragment_retries"], 20)

    def test_failed_extraction_is_not_repeated_by_gallery_dl(self):
        extr = extractor.find("https://hotleak.vip/example/")
        extr.initialize()
        job = SimpleNamespace(
            extractor=extr, out=Mock(),
            get_logger=lambda name: logging.getLogger(name),
        )
        downloader = YoutubeDLDownloader(job)
        pathfmt = SimpleNamespace(kwdict={})
        with patch.object(downloader, "_extract_url", return_value=None) as fetch:
            self.assertFalse(downloader.download("ytdl:https://example.invalid/1", pathfmt))
        self.assertEqual(fetch.call_count, 1)
        self.assertEqual(downloader.ytdl_instance.params["retries"], 10)

    def test_failed_video_does_not_block_next_image(self):
        extr = extractor.find("https://hotleak.vip/example/")
        video = {"creator": "example", "id": 1, "extension": "mp4", "type": "video"}
        later_video = {**video, "id": 3}
        photo = {"creator": "example", "id": 2, "extension": "jpg", "type": "photo"}
        messages = [
            (Message.Directory, "", video),
            (Message.Url, "ytdl:https://example.invalid/video/1", video),
            (Message.Directory, "", later_video),
            (Message.Url, "ytdl:https://example.invalid/video/3", later_video),
            (Message.Directory, "", photo),
            (Message.Url, "https://example.invalid/photo.jpg", photo),
        ]
        events = []

        def video_failure(downloader, instance, url):
            events.append("video")
            downloader.error = "HTTP Error 429: Too Many Requests"
            return None

        def image_download(downloader, url, pathfmt):
            events.append("image")
            Path(pathfmt.temppath).parent.mkdir(parents=True, exist_ok=True)
            Path(pathfmt.temppath).write_bytes(b"test-image")
            return True

        with tempfile.TemporaryDirectory() as directory:
            config.set(("extractor",), "base-directory", directory)
            with patch.object(extr, "items", return_value=iter(messages)), \
                    patch.object(extr, "sleep", side_effect=lambda *args: events.append("sleep")), \
                    patch.object(YoutubeDLDownloader, "_extract_url", video_failure), \
                    patch.object(HttpDownloader, "download", image_download), \
                    patch("gallery_dl.main", side_effect=lambda: job.DownloadJob(extr).run()):
                HELPERS["_run_gallery_dl"]()
            self.assertEqual(events, ["sleep", "video", "sleep", "image"])
            self.assertEqual(len(list(Path(directory).rglob("*.jpg"))), 1)

    def test_sleep_can_be_disabled(self):
        with patch.dict(HELPERS, STREAM_VIDEO_SLEEP=0.0):
            hotleak = HELPERS["_stream_pacing_config"]()["extractor"]["hotleak"]
        self.assertEqual(hotleak["sleep"], "0.0-0.0")

    def test_other_sites_are_not_overridden(self):
        self.assertEqual(set(self.managed["extractor"]), {"hotleak"})

    def test_config_append_is_ordered_and_idempotent(self):
        command = ["gallery-dl", "--config", "/config/gallery-dl.conf",
                   "-c", "/config/custom.conf", "--input-file", "urls.txt"]
        append = HELPERS["_append_stream_pacing_config"]
        append(command)
        append(command)
        managed = HELPERS["STREAM_PACING_CONFIG_FILE"]
        self.assertEqual(command.count(managed), 1)
        self.assertGreater(command.index(managed), command.index("/config/custom.conf"))
        other = ["yt-dlp", "https://example.invalid/video"]
        self.assertEqual(append(other.copy()), other)

    def test_download_launcher_only_wraps_gallery_dl(self):
        command = ["gallery-dl", "--input-file", "urls.txt"]
        launch = HELPERS["_download_process_args"]
        self.assertEqual(launch(command), [sys.executable, str(SOURCE), "--gallery-dl",
                                         "--input-file", "urls.txt"])
        self.assertEqual(command[0], "gallery-dl")
        other = ["yt-dlp", "https://example.invalid/video"]
        self.assertEqual(launch(other), other)


class VideoRateLimitTests(unittest.TestCase):
    def run_downloads(self, entries):
        attempted = []

        def download(job, url, metadata):
            attempted.append(metadata["id"])
            if error := metadata.get("error"):
                logging.getLogger("downloader.ytdl").error(error)

        def main():
            for site, metadata in entries:
                # Separate jobs mimic multiple creator URLs in urls.txt.
                current = SimpleNamespace(extractor=SimpleNamespace(category=site),
                                          log=logging.getLogger("test"))
                job.DownloadJob.handle_url(current, "https://example.invalid/media", metadata)

        with patch.object(job.DownloadJob, "handle_url", download), \
                patch("gallery_dl.main", side_effect=main):
            HELPERS["_run_gallery_dl"]()
            self.assertIs(job.DownloadJob.handle_url, download)
        return attempted

    def test_429_skips_later_videos_across_creators_but_not_images(self):
        entries = [
            ("hotleak", {"id": 1, "type": "video", "error": "HTTP Error 429: Too Many Requests"}),
            ("hotleak", {"id": 2, "extension": "mp4"}),
            ("hotleak", {"id": 3, "extension": "jpg"}),
            ("instagram", {"id": 4, "extension": "mp4"}),
        ]
        self.assertEqual(self.run_downloads(entries), [1, 3, 4])

    def test_other_errors_do_not_disable_videos(self):
        entries = [("hotleak", {"id": 1, "type": "video", "error": "HTTP Error 403: Forbidden"}),
                   ("hotleak", {"id": 2, "type": "video"})]
        self.assertEqual(self.run_downloads(entries), [1, 2])

    def test_image_429_does_not_disable_videos(self):
        entries = [("hotleak", {"id": 1, "extension": "jpg", "error": "HTTP Error 429"}),
                   ("hotleak", {"id": 2, "type": "video"})]
        self.assertEqual(self.run_downloads(entries), [1, 2])

    def test_other_site_429_does_not_disable_hotleak_videos(self):
        entries = [("instagram", {"id": 1, "extension": "mp4", "error": "HTTP Error 429"}),
                   ("hotleak", {"id": 2, "type": "video"})]
        self.assertEqual(self.run_downloads(entries), [1, 2])

    def test_next_run_tries_videos_again(self):
        self.run_downloads([("hotleak", {"id": 1, "type": "video", "error": "HTTP Error 429"})])
        self.assertEqual(self.run_downloads([("hotleak", {"id": 2, "extension": "mp4"})]), [2])


if __name__ == "__main__":
    unittest.main()
