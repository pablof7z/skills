---
name: tts
description: Generate speech from text with a Kokoro endpoint.
---

# TTS Skill

Generate spoken audio from text with a Kokoro-compatible endpoint.

## Input text rules

Use natural sentences for best results.

- **Acronyms**: Write as you'd type them — `CLI`, `API`, `HTTP`, etc. The skill auto-converts to `C L I`, `A P I`, `H T T P` for letter-by-letter pronunciation.
- **Abbreviations**: Expand when pronunciation matters — `AI` → `artificial intelligence`, `DB` → `database`, `API` → `application programming interface`.
- **Code & paths**: Avoid or rephrase — instead of `run /usr/local/bin/script`, say `run the script`.
- **Punctuation**: Natural pauses work; avoid excessive symbols.

## Available voices

American English (default): `af_bella`, `af_heart`, `af_kore`, `af_nova`, `af_sarah`, `am_michael`, `am_puck`

Other languages & accents available: British English, Japanese, Mandarin, French, Italian, Portuguese.
