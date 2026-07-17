import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


class MenuRecoveryTests(unittest.TestCase):
    def test_intentional_stop_parks_active_and_paused_items(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary)
            items = state / "items"
            items.mkdir()
            audio = state / "speech.mp3"
            audio.write_bytes(b"audio")
            self.write_item(items, "playing", "playing", audio)
            self.write_item(items, "paused", "paused", audio)
            self.write_item(items, "waiting", "queued", audio)

            subprocess.run(
                [sys.executable, str(self.recovery_script()), str(state)],
                check=True,
            )

            playing = self.read_item(items, "playing")
            paused = self.read_item(items, "paused")
            waiting = self.read_item(items, "waiting")
            self.assertEqual(playing["status"], "interrupted")
            self.assertEqual(paused["status"], "interrupted")
            self.assertIsNotNone(playing["completed_at"])
            self.assertIsNotNone(paused["completed_at"])
            self.assertTrue(playing["is_unheard"])
            self.assertTrue(paused["is_unheard"])
            self.assertEqual(waiting["status"], "queued")

    def write_item(self, items, item_id, status, audio):
        value = {
            "id": item_id,
            "status": status,
            "output_file": str(audio),
            "started_at": 10,
            "completed_at": None,
        }
        (items / f"{item_id}.json").write_text(json.dumps(value))

    def read_item(self, items, item_id):
        return json.loads((items / f"{item_id}.json").read_text())

    def recovery_script(self):
        return Path(__file__).parents[1] / "scripts" / "tts-menu-recover.py"


if __name__ == "__main__":
    unittest.main()
