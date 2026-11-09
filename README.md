# AudiotrackID

Portable Windows tool that finds video files in a folder, identifies the spoken language of every
audio track that has no language in its title (using Whisper), and tags/renames those tracks.

## Usage

Drag a folder (or video files) onto `AudiotrackID.cmd`, or from a console:

```
AudiotrackID.cmd "D:\Movies"                 # process folder recursively
AudiotrackID.cmd "D:\Movies" -DryRun         # show what would change, modify nothing
AudiotrackID.cmd "D:\Movies" -Model medium   # more accurate, slower
AudiotrackID.cmd "D:\Movies" -Normalize -NameFormat IsoUpper -UseLanguageTag
                                             # make every track title "CZE", "ENG - Commentary", ...
AudiotrackID.cmd -Setup                      # download/update all tools (for offline use)
```

| Option | Default | Meaning |
|---|---|---|
| `-Model` | `small` | Whisper model: `tiny`, `base`, `small`, `medium`, `large-v3`, `large-v3-turbo` |
| `-Device` | `Auto` | `Auto` benchmarks the CPU and every GPU once per machine and model, then uses the fastest. `Gpu` uses the fastest GPU, `Cpu` never uses a GPU |
| `-VerifyModel` | `large-v3-turbo-q5_0` | second opinion: when `-Model` is under `-VerifyBelow`, the same excerpts are re-checked with this larger model. It is far better with accents (e.g. Scottish English) but ~5× slower on CPU. `''` disables it |
| `-VerifyBelow` | `0.9` | confidence under which the second opinion is requested |
| `-Samples` | `6` | random excerpts per track (a 2nd round is taken automatically if unclear) |
| `-SampleSeconds` | `30` | seconds of audio per excerpt (Whisper uses at most 30) |
| `-MinConfidence` | `0.6` | below this the track is reported as uncertain and left unchanged |
| `-DryRun` | | detect only, don't write |
| `-NameFormat` | `Name` | how the language is written in titles: `Name` → `Czech`, `Iso` → `cze`, `IsoUpper` → `CZE` |
| `-Normalize` | | also rename tracks that already name a language, into the `-NameFormat` form (`CZ Dabing DTS` → `Czech - Dabing DTS`). The language comes from the title; Whisper isn't run. A title naming several languages (`CZ/EN`) is left alone |
| `-UseLanguageTag` | asks | quick path: an untitled track that already has a language tag (`cze`, `cs-CZ`, ...) is named from the tag instead of being run through Whisper. If you leave this out and such tracks exist, you are asked interactively. `-UseLanguageTag:$false` turns the question off |
| `-Force` | | run Whisper on every track, ignoring titles and tags |
| `-ReplaceTitle` | | `Stereo` → `Czech` instead of `Czech - Stereo` |
| `-NoRecurse` | | don't scan subfolders |
| `-Report file.csv` | | write a CSV report |

## How it works

1. `ffprobe` lists the audio tracks; a track is skipped if its title already contains a language
   (`English`, `CZ`, `Česky`, `[ENG]`, `Deutsch`, `日本語`, ...).
2. For every other track, random positions are chosen across the whole track (stratified: one per
   segment, skipping the intro and end credits). For each, `ffmpeg` seeks there and decodes only
   ~90 s of that track, strips silence and keeps 30 s at 16 kHz mono. For surround tracks only the
   center (dialogue) channel is used, so music and effects get in the way much less. **The track is
   never extracted in full.**
3. `whisper-cli` (whisper.cpp) runs language detection on the excerpts with Silero VAD, so excerpts
   with only music, effects or noise don't count. Results are combined as votes weighted by probability.
   If the fast `small` model is under 90 % sure, the same excerpts are re-checked with `large-v3-turbo`.
4. If the result is confident enough, the language tag (ISO 639-2) and title are written:
   * **MKV / WebM / MKA**: in place with `mkvpropedit` (instant, no rewrite)
   * **MP4 / MOV / AVI / TS / ...**: lossless `ffmpeg -c copy` remux to a temp file. It is checked,
     swapped in, and the original modification time is kept.

## GPU acceleration

Any GPU with a Vulkan driver works: AMD, Intel or NVIDIA, including integrated graphics. whisper.cpp
has no Vulkan build for Windows, so the tool combines its `whisper-cli` with the GPU backend DLLs from
the matching llama.cpp release (`tools\whisper-vulkan\`). The versions are pinned in the script
(`$WhisperRelease`, `$LlamaRelease`) and tested together.

The first time a model is used on a machine, the tool times the CPU and each GPU on a short test
clip, uses the fastest, and remembers the choice in `tools\device-cache.json`. When the folder is
copied to another PC, the test runs again there. If a GPU run fails, it falls back to the CPU.

Example (Ryzen 7 8840HS, Radeon 780M integrated GPU): `large-v3-turbo` took 31.5 s on the CPU and
5.7 s on the GPU in the benchmark. A whole film took 222 s on the CPU and 51 s on the GPU.

## Portability

Nothing needs to be installed. On first run (or with `-Setup`) everything is downloaded
automatically into `tools\` next to the script. That is about 1.4 GB, mostly ffmpeg and the two
Whisper models:

```
tools\ffmpeg\      ffmpeg.exe, ffprobe.exe          (BtbN static build)
tools\whisper\     whisper-cli.exe + DLLs           (ggml-org/whisper.cpp, CPU x64)
tools\whisper-vulkan\  same + Vulkan ggml DLLs      (from ggml-org/llama.cpp Vulkan build)
tools\mkvtoolnix\  mkvpropedit.exe                  (MKVToolNix portable)
tools\models\      ggml-small.bin, ggml-large-v3-turbo-q5_0.bin, Silero VAD model
```

After that the folder works offline and can be copied anywhere. It runs on stock Windows 10/11
(Windows PowerShell 5.1 or PowerShell 7); nothing is installed system-wide.
