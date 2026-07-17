# shellcheck shell=bash

prepare_attachment_manifest() {
  local manifest="$1"
  shift
  python3 - "$manifest" "$SCRIPT_DIR" "$@" <<'PY'
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile

manifest = Path(sys.argv[1])
sys.path.insert(0, sys.argv[2])
from tts_attachment_text import narrated_attachment_speech

values = sys.argv[3:]
if len(values) % 2:
    raise SystemExit("attachment labels and paths must be paired")

image_extensions = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".tif", ".tiff", ".svg"}
diagram_extensions = {".mmd"}
audio_extensions = {".mp3", ".m4a", ".wav", ".aac", ".aiff", ".caf"}
text_extensions = {".md", ".markdown", ".txt"}
attachments = []
manifest.parent.mkdir(parents=True, exist_ok=True)

for index in range(0, len(values), 2):
    label = values[index].strip()
    source = Path(values[index + 1]).expanduser().resolve()
    if not label:
        raise SystemExit("attachment labels cannot be empty")
    if not source.is_file():
        raise SystemExit(f"attachment does not exist or is not a file: {source}")
    number = index // 2 + 1
    slug = re.sub(r"[^A-Za-z0-9]+", "-", label).strip("-").lower() or "attachment"
    attachment_id = f"{number:02d}-{slug[:48]}"
    directory = manifest.parent / attachment_id
    directory.mkdir(parents=True, exist_ok=True)
    copied = directory / ("source" + source.suffix.lower())
    shutil.copy2(source, copied)
    extension = copied.suffix.lower()
    kind = "file"
    status = "ready"
    audio_file = None
    text = None
    if extension in text_extensions:
        try:
            narrated_attachment_speech(label, copied)
        except ValueError as error:
            raise SystemExit(str(error)) from error
        kind = "narrated_text"
        status = "preparing"
        audio_file = str(directory / "narration.mp3")
    elif extension in image_extensions:
        kind = "image"
    elif extension in diagram_extensions:
        kind = "diagram"
        text = copied.read_text(encoding="utf-8")
    elif extension in audio_extensions:
        kind = "audio"
        audio_file = str(copied)
    attachments.append(
        {
            "id": attachment_id,
            "label": label,
            "kind": kind,
            "status": status,
            "source_file": str(copied),
            "text": text,
            "audio_file": audio_file,
            "word_timings": None,
            "error": None,
        }
    )

descriptor, temporary_name = tempfile.mkstemp(prefix=".attachments-", dir=manifest.parent)
temporary = Path(temporary_name)
try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(attachments, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(temporary, manifest)
finally:
    temporary.unlink(missing_ok=True)
PY
}

prepare_question_bundle() {
  local destination="$1"
  local raw_bundle="$2"
  local root_manifest="$3"
  local item_directory="$4"
  python3 - "$destination" "$raw_bundle" "$root_manifest" "$item_directory" "$SCRIPT_DIR" <<'PY'
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile

destination = Path(sys.argv[1])
bundle = json.loads(sys.argv[2])
root_manifest = Path(sys.argv[3]) if sys.argv[3] else destination.parent / "attachments" / "manifest.json"
item_directory = Path(sys.argv[4])
sys.path.insert(0, sys.argv[5])
from tts_attachment_text import narrated_attachment_speech

image_extensions = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".tif", ".tiff", ".svg"}
diagram_extensions = {".mmd"}
audio_extensions = {".mp3", ".m4a", ".wav", ".aac", ".aiff", ".caf"}
text_extensions = {".md", ".markdown", ".txt"}

def atomic_write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.stem}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)

def copy_attachment(spec, attachment_id, directory):
    source = Path(spec["path"]).expanduser().resolve()
    if not source.is_file():
        raise SystemExit(f"attachment does not exist or is not a file: {source}")
    label = spec.get("label") or source.stem
    directory.mkdir(parents=True, exist_ok=True)
    copied = directory / ("source" + source.suffix.lower())
    shutil.copy2(source, copied)
    extension = copied.suffix.lower()
    kind = "file"
    status = "ready"
    audio_file = None
    text = None
    if extension in text_extensions:
        try:
            narrated_attachment_speech(label, copied)
        except ValueError as error:
            raise SystemExit(str(error)) from error
        kind = "narrated_text"
        status = "preparing"
        audio_file = str(directory / "narration.mp3")
    elif extension in image_extensions:
        kind = "image"
    elif extension in diagram_extensions:
        kind = "diagram"
        text = copied.read_text(encoding="utf-8")
    elif extension in audio_extensions:
        kind = "audio"
        audio_file = str(copied)
    return {
        "id": attachment_id,
        "label": label,
        "description": spec.get("description"),
        "kind": kind,
        "status": status,
        "source_file": str(copied),
        "text": text,
        "audio_file": audio_file,
        "word_timings": None,
        "error": None,
    }

root_attachments = []
if root_manifest.is_file():
    loaded = json.loads(root_manifest.read_text(encoding="utf-8"))
    if isinstance(loaded, list):
        root_attachments.extend(loaded)
questions = []
for question_index, raw_question in enumerate(bundle["questions"], 1):
    question_id = f"q-{question_index:02d}"
    question_directory = item_directory / "questions" / question_id
    question_attachments = [
        copy_attachment(spec, f"{question_id}-a-{index:02d}", question_directory / "attachments" / f"a-{index:02d}")
        for index, spec in enumerate(raw_question.get("attachments") or [], 1)
    ]
    suggestions = []
    for suggestion_index, raw_suggestion in enumerate(raw_question.get("suggestions") or [], 1):
        suggestion_id = f"{question_id}-s-{suggestion_index:02d}"
        suggestion_directory = question_directory / "suggestions" / suggestion_id
        suggestion_attachments = [
            copy_attachment(spec, f"{suggestion_id}-a-{index:02d}", suggestion_directory / "attachments" / f"a-{index:02d}")
            for index, spec in enumerate(raw_suggestion.get("attachments") or [], 1)
        ]
        suggestions.append({
            "id": suggestion_id,
            "title": raw_suggestion["title"],
            "description": raw_suggestion.get("description"),
            "attachments": suggestion_attachments,
        })
    questions.append({
        "id": question_id,
        "short_title": raw_question["short_title"],
        "title": raw_question["title"],
        "type": raw_question.get("type", "single_choice"),
        "description": raw_question.get("description"),
        "attachments": question_attachments,
        "suggestions": suggestions,
        "status": "pending",
        "response": None,
    })

prepared = {
    "questions_preamble": bundle.get("questions_preamble"),
    "questions": questions,
}
atomic_write(root_manifest, root_attachments)
atomic_write(destination, prepared)
PY
}

prepare_scoped_attachment_narrations() {
  local bundle_file="$1"
  local voice="$2"
  local work_file="$ITEM_DIRECTORY/scoped-attachments-work.json"
  local prepared_file="$ITEM_DIRECTORY/scoped-attachments-prepared.json"
  if ! python3 - "$bundle_file" "$work_file" "$voice" <<'PY'
import json
import sys
bundle_file, work_file, voice = sys.argv[1:]
bundle = json.load(open(bundle_file, encoding="utf-8"))
attachments = []
for question in bundle.get("questions") or []:
    attachments.extend(question.get("attachments") or [])
    for suggestion in question.get("suggestions") or []:
        attachments.extend(suggestion.get("attachments") or [])
pending = [value for value in attachments if value.get("kind") == "narrated_text" and value.get("status") == "preparing"]
if not pending:
    raise SystemExit(1)
with open(work_file, "w", encoding="utf-8") as handle:
    json.dump({"voice": voice, "attachments": pending}, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
  then
    return 0
  fi
  echo "Preparing scoped narrated question attachments..." >&2
  if ! "$SCRIPT_DIR/tts-attachment-worker" "$work_file" </dev/null >&2; then
    echo "Warning: one or more scoped question attachments could not be narrated." >&2
  fi
  python3 - "$bundle_file" "$work_file" "$prepared_file" <<'PY'
import json
import os
import sys
bundle_path, work_path, prepared_path = sys.argv[1:]
bundle = json.load(open(bundle_path, encoding="utf-8"))
work = json.load(open(work_path, encoding="utf-8"))
by_id = {value["id"]: value for value in work.get("attachments") or []}
for question in bundle.get("questions") or []:
    question["attachments"] = [by_id.get(value["id"], value) for value in question.get("attachments") or []]
    for suggestion in question.get("suggestions") or []:
        suggestion["attachments"] = [by_id.get(value["id"], value) for value in suggestion.get("attachments") or []]
with open(prepared_path, "w", encoding="utf-8") as handle:
    json.dump(bundle, handle, ensure_ascii=False, indent=2, sort_keys=True)
    handle.write("\n")
os.replace(prepared_path, bundle_path)
PY
  rm -f "$work_file"
}
