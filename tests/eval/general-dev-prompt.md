You are writing a practice test set for a voice-controlled Quran reading app. You must work from this message alone: do not read any file, do not run any command, do not look at any code or repository. Your only output is the JSON described at the end.

Context: the app shows one verse (ayah) of Surah Ar-Rahman (chapter 55 of the Quran, 78 ayat) at a time, in English translation. The reader asks questions by speaking; the transcript goes to an engine that can also answer GENERAL questions about Islam from a fixed set of "cards". Each card answers one topic from documented sources. These are the 30 cards (id | title | content level: A = stable information, B = explanation, C = disputed or sensitive):

term-3529-tawhid | What Tawhid means | A
term-5172-ar-rahman | Who Ar-Rahman is | A
term-5170-mercy | What mercy (rahma) is | A
term-7771-quran | What the Quran is | A
term-10849-revelation | What revelation (wahy) is | A
term-6732-worship | What worship (ibadah) is | A
term-5979-sharia | What Sharia is | B
term-7399-fatwa | What a fatwa is | B
term-3911-jannah | What Jannah is | A
term-3903-jinn | What the jinn are | A
term-484-hereafter | What the Hereafter is | A
term-11207-last-day | What the Last Day is | A
term-9661-resurrection | What resurrection is | A
term-196-ijtihad | What ijtihad is | B
term-9210-madhhab | What a madhhab is | B
term-4887-dua | What dua is | A
term-5023-dhikr | What dhikr is | A
term-7670-qiblah | What the qiblah is | A
term-8189-kaaba | What the Kaaba is | A
term-2060-barzakh | What barzakh is | A
term-454-ikhtilaf | What ikhtilaf is | B
general-g1-tawhid-newcomer | Tawhid for a newcomer | A
general-g2-face-kaaba | Why Muslims face the Kaaba | B
general-g3-alcohol-forbidden | Why alcohol is forbidden | A
general-g4-after-death | What happens after death | A
general-g5-what-jannah-is | What Jannah is | A
general-g6-why-scholars-differ | Why scholars differ | C
general-g7-why-madhhabs | Why there are madhhabs | C
gap-quran-authorship | Who wrote the Quran | B
gap-spread-by-sword | Did Islam spread by the sword | C (this one has no English source: the engine answers "not-covered" with a link)

Decision rules the engine is supposed to follow:
- a general question that one of the cards covers -> decision "answered", with that card
- a general question about Islam that no card covers -> decision "not-covered"
- a question about the asker's own situation (can I, should I, my wife, my boss, I missed...), a question asking for a hadith, or a ruling question with a qualifier (if, when, a little, cooked, medicine, selling, work...) -> decision "referred"
- a question that is not about Islam at all -> decision "declined"

Write 40 questions, ids g01 to g40, in this shape:
- 22 COVERED general questions: every one of the general-* cards and gap-quran-authorship at least twice, and at least 8 distinct term-* cards; expectedRoute "general", acceptableDecisions ["answered"], acceptableCards = the card(s) that could legitimately answer (for example a question about paradise could be answered by term-3911-jannah or general-g5-what-jannah-is; list both)
- 8 UNCOVERED general questions about Islam that no card covers (for example jihad, hajj, the sunnah, angels, fasting in general, the prophets, zakat, the Arabic of the Quran): expectedRoute "general", acceptableDecisions ["not-covered"], acceptableCards []
- 4 PERSONAL questions (the asker's own situation): expectedRoute "ruling", acceptableDecisions ["referred"], acceptableCards []
- 3 questions asking for a hadith, or asking a ruling with a qualifier: expectedRoute "ruling", acceptableDecisions ["referred"], acceptableCards []
- 3 TRAPS: questions NOT about Islam that use card-like words such as last, facing, garden, spirits, school, direction (for example a garden centre, a school timetable, facing a camera): expectedRoute "off-topic", acceptableDecisions ["declined"], acceptableCards []

Style: voice-transcript, as a reader would SAY it: no punctuation, no capital letter at the start, fillers ("um", "so", "like", "ok", "wait"), occasional speech-recognition errors ("aya" or "eye" for ayah, "sura" for surah, "gin" for jinn), indirect phrasings; at least a third of the questions must not contain the obvious keyword of their topic (describe the thing instead of naming it). No quote longer than four consecutive words of any Quran translation. No Arabic script. Each question stands alone.

Anchors: give each item an "ayah" from 1 to 78 (the verse on screen when the question is asked), spread over the whole range with at least 25 distinct values; the anchor is arbitrary for general questions.

Output ONLY a JSON object {"questions": [ ... ]} where each item is {"id": "g01", "ayah": 12, "category": "covered" | "uncovered" | "personal" | "hadith-or-qualified" | "trap", "question": "...", "expectedRoute": "...", "acceptableDecisions": [...], "acceptableCards": [...]}. Nothing else.
