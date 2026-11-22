---
name: talk-deck
description: >-
  Procedure for making a talk or slide deck that the person giving it will accept,
  from agreeing the message and audience to handing over rendered, checked slides.
  Use when asked to make, draft, rebuild or revise a talk, a slide deck, a
  presentation, a demo or a tour for colleagues, and when revising one after
  comments. Works with any renderer (an HTML page, the pptx skill, a slide
  artifact); includes a checker for word caps and sourced numbers. Built from the
  owner's corrections of one deck over 2026-11-20 to 2026-11-22.
---

# Talk deck

Every rule below exists because the owner (the person giving the talk, who accepts
the deck) had to ask for it. Each carries the date and the owner's own words. The deck
that taught these went through several rebuilds; the aim here is to get there in one.

This skill is a procedure. It never builds a deck: use the renderer the owner already
has (a single HTML page, the `pptx` skill, a slide artifact, Markdown slides) and make
this procedure govern what goes on the slides. The checker is
`scripts/check_deck.py` (section 5).

## 1. Before building anything

1. **Agree the message and the audience, in two sentences, before drafting.** What
   should the audience leave knowing or able to do, and what do they already know?
   Ask if you cannot state it.
   - 2026-11-20, the brief: "I want to show my colleagues how our setup works, where
     it helps & how." and "I gave them the repos but that isn't really that helpful.
     as they need to read a lot." (so the talk carries the content; the audience will
     not read the source.)
   - 2026-11-22, after a first deck that listed results: "it reads like a highlights
     overview package, that this is what I've done, or it doesn't really say how." and
     "these people want to learn the good practices that we have done, how we have
     done it, without going into text bloat or too much commentary."
   - 2026-11-22: "Objective is not to highlight, okay, this is the great stuff we have
     done. Yes, fine, but how we have done it. So that they can understand. They are
     technical people." Teach the practice (what goes wrong without it, how it works),
     and let numbers support it.
2. **Agree the length and the slide list.** 2026-11-22: "I don't want like 50-slide
   deck. Number of slides can remain the same, but the organization has to be better."
   and "And I think we have too many case studies." A fix reorganises; it does not
   add slides, and it cuts repeats.
3. **Pick the renderer and the recency window** (section 4) now, not after the build.

## 2. One prototype slide, then the owner's go, then the rollout

Build exactly one slide of the most common kind, render it (section 5), show it, and
wait. Only after the owner's go, apply the pattern to every slide of that kind.
- 2026-11-22, the owner asked for it: "Can you build it for this particular slide
  number 7, so that I can visualize it and check it?" The reply to the first
  prototype was "very good"; that was the go for the pattern.
- The same day, when the pattern had reached only some slides: "Slides 1 to 10 look
  really good. Why haven't you modified other slides?" When a pattern is approved,
  apply it to every slide it fits in the same pass, and list any slide you left
  unchanged with the reason.
- A slide the owner praised stays. 2026-11-22: "demo itself is good, it should stay
  there." Add what is missing around it ("But it doesn't discuss why is it important,
  how does it help"); do not rebuild it.

## 3. Per-slide rules

Check each before showing a slide.

- **One message per slide, and the slide says what to look at.** 2026-11-22: "This one
  at least has a figure, so it's good, but I have no idea what are we trying to
  highlight over here. What did our setup help?" Every figure carries a short label
  that says the message or what to look at; no figure is left to explain itself.
- **Pictures over prose.** Replace sentences with a step strip, a before and after
  pair, a bar, a ladder or a row of labelled boxes with arrows. A picture carries at
  most one short note line.
  - 2026-11-21: "it's too text heavy, when I look at this 93% 327k etc on first glance
    doesn't tell me what it's talking about."
  - 2026-11-22: "So text heavy. Very difficult to understand. How this has been
    achieved." and, of a slide with bullets only, "this one is very bland, hard to
    follow, basically text."
  - 2026-11-22, on a prototype that was better but still wordy: "This is much better,
    but I still feel that text can be cut. With clever ways. So not just two lines of
    text, maybe this arrow, this arrow, this, or something, some clever way of doing
    it."
  - 2026-11-22, what a concept slide should be: "very to the point, something that
    explains what a hook is, what a guard is, what a policy is, how do we enforce
    that, where do they go, some visual, something like that."
- **Word caps, counted by the checker.** A closed slide (what a viewer reads without
  opening anything): 80 words, diagram labels included. A click-to-open panel: 45
  words, in plain language. History: the cap was 50 on 2026-11-21 and became 80 on
  2026-11-22 when diagram labels counted; the 45-word panel cap dates from
  2026-11-21. Words in verbatim excerpts (a real log, a real quote) sit outside the
  caps; mark them (section 5). A slide that needs a different cap declares it, and the
  reason goes in the hand-over note.
- **Details open on click, never by default, and never in one dump.**
  - 2026-11-21: "Also, there is a detail section right at the bottom. That's not good
    enough." and "Every bullet point that might have details, we can just click here
    and open something." and "That might be useful to point out, but not by default."
  - 2026-11-21, on a details panel that held a citation list: "Also, look at the
    details, utter garbage. Looks so ugly. Who is going to read that?" A panel names
    its source in words; paths and line numbers go in the facts file (section 4).
  - One panel open at a time on a slide; a print or handout view may open them all.
- **An optional layer of real text.** 2026-11-22: "might also be useful to have
  another drop-down for the details if people are interested to show them the
  snippets of our rules or snippets of skill or something if it is useful." Offer it
  as a second, nested click-to-open layer holding an excerpt copied from the live
  file at build time (never retyped), so the slide stays short. Propose it; the owner
  decides.
- **Controls are visible.** 2026-11-21: "And how do I go to the next slide? I can't
  even find any button that allows me to go to the next slide." Keyboard keys are not
  enough: show previous and next buttons and a slide counter, and say the keys once on
  the title slide.
- **Problem before solution.** For any practice, tool or system, the slide order is:
  what goes wrong without it (a dated incident), how it works (a mechanism picture),
  what it gets you (a recent number). Template: `templates/explain-a-system.md`.
  - 2026-11-22: "We need to explain what happens if we don't do that, and how, what
    are we doing? What are the results?"
  - 2026-11-22: "if you just use Claude out of box, what would happen?" then "So we
    need to explain that first. Then we need to explain how we are solving it."
  - 2026-11-22: "But it doesn't discuss why is it important, how does it help".

## 4. Numbers

- **Every number has a plain label, a unit, a date and a source.** A number shown
  alone does not say what it is about (2026-11-21, "when I look at this 93% 327k etc
  on first glance doesn't tell me what it's talking about."): put a two-to-five-word
  label of what it measures directly under it. The facts file holds one row per
  number: value with unit, date, source (a file and line, a log, a run); the slide
  names the source in words only.
- **Recent numbers only, for anything that changes.** 2026-11-22: "So probably best
  to quote numbers from the last month or last 2 months or statistics from a couple of
  months" and "So if we compare with models from 6 months ago, that is not a fair
  comparison." Agree a window (for example the last two months) at the start; the
  checker's `--window-start` fails a result dated before it. An older incident may
  appear only as a dated "what went wrong" event, never as a result.
- **Numbers are checked against their source by reading it.** The agreed check of
  2026-11-20: "Every number on a slide matches its cited source line (checked by
  reading each source, not by trusting the brief)." The checker proves the facts row
  exists and is dated and sourced; it cannot prove the row is right.
- **Quotes of people are lightly edited, and the slide says so.** 2026-11-20: "yes
  fine but correct my grammr mistakes, typos etc." A quote that states something
  technically wrong is not used.

## 5. Render, look, check, cold read

1. **Render every slide and look at it** before handing over. For HTML: a headless
   browser screenshot of each slide at the projector size and at laptop size, offline,
   with no console errors; then open each image. Also drive the controls (next,
   previous, any click-to-open panel) the way the audience will. For `pptx`: convert
   to images and look at each. The agreed check of 2026-11-20: "Every slide renders
   with no console error in headless Chrome or Chromium, offline (network disabled)".
   Nothing counts as checked that was only read as source.
2. **Run the checker** on the source deck:
   `python3 scripts/check_deck.py DECK --facts FACTS.md [--window-start YYYY-MM-DD]`.
   It exits 1 naming each slide, the rule and the remedy; fix and rerun until it exits
   0. Facts file: a Markdown table with the columns `value`, `date`, `source`.
   Settings can sit in `deck-check.json` beside the deck (`slide_selector` default
   `section`, `panel_selector` default `details`, `ignore_selector`, `max_slide_words`
   80, `max_panel_words` 45, `facts`, `window_start`). Mark verbatim logs and quotes
   `data-verbatim` so they sit outside the caps. A Markdown deck separates slides with
   `---` lines. Pass is a floor, not the bar: it does not judge whether a slide is
   understood.
3. **Cold read.** The agreed check of 2026-11-20: "A cold read by someone without this
   conversation finds every slide understandable." Give a fresh reader (a new agent
   with only the slide images and the title, no brief) this prompt: "You are in the
   audience. For each slide: what is its one message, what would you look at first,
   and what did you not understand? Do not be kind." A slide whose message they
   cannot state back is rebuilt, not annotated.
4. **Hand over** with full absolute paths: the deck, the facts file, the screenshots.
   State what was checked (renders, checker, cold read) and what was not.

## 6. Revising after comments

Take the owner's comments as a pattern, not a patch: find every slide the same
criticism applies to (see "Slides 1 to 10 look really good. Why haven't you modified
other slides?" in section 2), fix them in one pass, rerun the checker and re-render.
If a comment is a question ("Do you agree with that?"), answer it first and agree the
fix before changing slides. Add any correction that this procedure lacks to it with
its date and the owner's words.
