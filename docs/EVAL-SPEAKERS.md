# Measuring speaker labels: `hearsay --eval-speakers`

Speaker rules (when a line is cut on a change of speaker, which slot a word goes to, any smoothing)
change only when a run of this harness says they are better. It replays real meeting audio through
the exact live pipeline (speech model, diarizer, `UtteranceTracker`) and scores the lines against a
word-level reference of who said what.

## Data: AMI, single distant microphone

The [AMI Meeting Corpus](https://groups.inf.ed.ac.uk/ami/corpus/) (CC BY 4.0): four people around a
table, recorded by one microphone in the middle of it (`Array1-01`, the "SDM" condition), which is
the shared-MacBook meeting. The reference is AMI's manual word-level transcription (`words/*.xml`
in `ami_public_manual_1.6.2.zip`): every word with its speaker and start/end time.

```sh
python3 -I scripts/ami-eval-prep.py ~/hearsay-eval     # ~290 MB download, once
```

writes, for a fixed list of six meetings (ES2004a, ES2014a, IS1009a, TS3003a, TS3007a, EN2002a;
AMI test-set meetings, all with four speakers), the ten minutes from 1:00 to 11:00 as
`NAME.wav` (16 kHz mono, peak-normalised to −1 dBFS) and `NAME.words.tsv` (`start end speaker
word`, seconds into the clip). The normalisation matters: the array microphone records speech
around −50 dBFS, below the tracker's −44 dBFS voice gate, so unnormalised every word would read
as silence and lines would be cut mid-word; a laptop's input gain puts the same room at roughly
−35…−25 dBFS, which is where the normalised clips land. The data stays outside the repository.

## Running

```sh
swift build -c release
.build/release/hearsay --eval-speakers ~/hearsay-eval                 # current defaults
.build/release/hearsay --eval-speakers ~/hearsay-eval --speaker-hold 1.5
.build/release/hearsay --eval-speakers ~/hearsay-eval --diarize lseend
```

Options: `--diarize sortformer|lseend|lseend-ami`, `--only NAME` (repeatable), `--dump DIR` (writes
each meeting's lines as `NAME.lines.tsv`), `--realtime` (paced like a live session; also reports
how long after its end each line arrived), `--variant NAME`, and the tracker experiments
`--speaker-hold S`, `--cut-at-pause [--cut-pause S] [--cut-window S]`, `--smooth-aba [--aba-words
N] [--aba-seconds S] [--aba-gap S]`. The same tracker flags work on `--transcribe`. No stored
preference and no enrolled voice is used. Six meetings take about five minutes unpaced on an M4.

Unpaced runs give the same lines as `--realtime` (the tracker counts samples, never the wall
clock): checked byte for byte on ES2004a.

## What the columns mean

| column | |
|---|---|
| acc | Word-level speaker accuracy: of the reference words that pair with an output word, the share whose line's speaker is that person. Output speaker slots are mapped to people one-to-one, the mapping that maximises this (per meeting); an unmapped slot or a line without a speaker is wrong |
| split/100 | Reference turns (one person's words with gaps under 1 s; someone talking over them does not end the turn) whose words landed in lines of two or more different speakers, per 100 turns (count in brackets). `strict` needs two words on each of two speakers |
| splitW | Words of split turns outside the turn's main speaker |
| merged, mergedW | Output lines holding words of two or more people, and their minority words |
| interj | Short-interjection recall: turns of 1.5 s or less ("yeah", "right") whose words mostly landed in lines attributed to their speaker (count in brackets) |
| lines, cuts | Output lines; lines cut on a speaker change |
| WER | Word error rate against the same reference (lowercase, punctuation stripped). A sanity check that a speaker rule left the text alone; far-field AMI is hard, so the absolute value is high |
| lag | `--realtime` only: mean seconds from a line's end to its arrival |

**Alignment.** An edit-distance alignment of the output words to the reference words, in which an
output word may only pair with a reference word spoken inside its line's span ± 1 s. Lines carry no
per-word times, so within a line the words are spread evenly over its span; the time window keeps
a repeated "yeah" from pairing with one a minute away. Overlapped speech is aligned in time order,
so some words of two people talking at once count as deletion + insertion: the same for every
configuration. The code is `SpeakerScore` (unit-tested in `SpeakerScoreTests`).

## Results

See `docs/PERFORMANCE.md` (Telling speakers apart) for the current table and the decision.
