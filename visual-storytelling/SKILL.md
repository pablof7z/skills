---
name: visual-storytelling
description: "Turn abstract ideas, arguments, processes, strategies, and narratives into original conceptual visuals, sparse editorial diagrams, single-image metaphors, carousels, storyboards, or production-ready visual briefs. Use when Codex needs to make a complex idea simple, communicate or narrate visually, create a Visualize Value-inspired concept, design a high-contrast idea card, build a visual essay, or make spatial metaphor and minimal copy carry the meaning. Do not use for quantitative data visualization, ordinary UI wireframes, decorative illustration with no explanatory purpose, or exact reproduction of a referenced creator's work."
---

# Visual Storytelling

Make the idea visible before making it beautiful. Compress the subject into one
legible relationship, embody that relationship in space, and reveal only what
the audience needs at each beat.

Treat Visualize Value as a reference for transferable mechanisms: conceptual
compression, strict constraints, familiar symbols, high contrast, negative
space, and concise language. Create new metaphors and compositions for the
user's subject. Never reproduce a specific post, slogan, signature composition,
logo, or brand mark.

## Establish the Output Contract

Identify the requested medium, audience, source idea, and intended realization:

- Produce the finished artifact when the user asks for an image, SVG, slide,
  carousel, storyboard, or other renderable output.
- Produce an implementation-ready brief when the user asks for a concept,
  direction, prompt, or specification.
- Select a single square visual for a short self-contained idea and a sequence
  for an argument with a genuine change over time.
- Ask one focused question only when the central claim, audience, or required
  medium cannot be inferred safely. Otherwise state the assumption and proceed.
- Preserve the user's factual meaning. Verify unstable or consequential claims
  before turning them into confident visual assertions.

## Build the Semantic Spine

Reduce the input to one plain causal or relational sentence. Prefer forms such
as:

```text
More X creates less Y.
What looks like X is actually Y.
X passes through Y and becomes Z.
Small repeated X accumulates into Y.
X and Y appear opposed but share Z.
Removing X reveals Y.
```

Name the load-bearing nouns, the change, and the tension. Remove background
facts that do not alter the relationship. If the idea cannot survive as one
sentence, split it into a sequence instead of shrinking the type.

Ground the sentence in source material, evidence, or a real observation. Test
it against more than one relevant example when possible. Generalize only far
enough that the audience can place its own experience into the idea; do not
generalize past what the source can support.

## Find the Visual Metaphor

Read [visual-grammar.md](references/visual-grammar.md) when selecting primitives,
metaphors, or composition. Generate at least three materially different
candidates in working notes. Vary the relationship, not merely the decoration.

Choose the candidate that best satisfies all four conditions:

1. Recognize the objects without explanation.
2. Understand the primary relationship at thumbnail size.
3. Discover a useful reframe on a second look.
4. Preserve the source idea without leaning on borrowed imagery.

Prefer ordinary visual nouns—line, gap, wall, ladder, weight, shadow, path,
container, lens, loop, signal, stack—used in a precise relationship. Do not add
symbols simply because they look conceptual.

For a logo, identity, or recurring symbolic system, test the concept as
structure, meaning, and deployment. Seek a familiar symbol whose operation can
be shifted or inverted to embody the subject's thesis, then prove that it still
works at small sizes and across real contexts.

## Shape the Story Unit

Use one frame for one simultaneous relationship. Use multiple frames only when
the audience must experience order, escalation, reversal, accumulation, or
reveal.

Read [story-structures.md](references/story-structures.md) when producing a
carousel, storyboard, motion concept, presentation sequence, or long-form visual
essay. Give every frame one job. Let the visible state change between frames;
do not turn a paragraph into a sequence of quotation cards.

Use the medium's native reveal mechanism. A swipe can disclose a missing half,
a presentation can progressively assemble a system, and motion can make cause
and effect visible. Do not paste the same pacing onto every platform.

For a compact sequence, default to:

1. Establish the familiar model.
2. Introduce pressure, contradiction, or missing context.
3. Make the hidden relationship visible.
4. Land the reframe or consequence.

Remove any frame whose absence does not change comprehension or pacing.

## Direct the Composition

Start with a constraint system before styling individual elements:

- Use one dominant relationship and one clear focal point.
- Start in monochrome. Add one accent only when it encodes state, direction, or
  emphasis that contrast alone cannot carry.
- Use a small vocabulary of geometric or familiar representational forms.
- Default a single-frame concept to no more than three shape families and 12
  on-canvas words. Exceed either only when the subject genuinely requires an
  information graphic.
- Use one headline or one turn by default, not a headline, diagram labels,
  caption, footer, and metadata competing inside the same frame.
- Reserve negative space as an active part of the explanation.
- Establish hierarchy through scale, position, weight, and spacing before color.
- Label only the nouns or transitions that would otherwise be ambiguous.
- Keep exact typography and geometry under deterministic control when text must
  render perfectly; prefer SVG, HTML/CSS, or native layout tools over raster
  generation for text-heavy work.
- Use raster generation for texture, material metaphor, atmosphere, or scenes
  whose value depends on illustration rather than exact labels.

Make the visual readable without its caption. Make the caption valuable without
restating the visual.

Run the TRAIN pass from [visual-grammar.md](references/visual-grammar.md):
Typography, Restraint, Alignment, Image treatment, and Negative space. Make one
constraint decision that removes many later style decisions.

## Write the Verbal Layer

Read [narration-grammar.md](references/narration-grammar.md) when writing the
turn, caption, sequence copy, spoken narration, or visual essay.

Use short, direct language. Lead with the claim or tension. Prefer concrete
nouns, active verbs, contrast, reversal, and parallel structure. Cut setup,
hedging, filler, and motivational wallpaper.

Use text in three distinct roles:

- **Label:** identify an otherwise ambiguous object or state.
- **Turn:** reveal the reframe the composition has prepared.
- **Caption:** extend the implication beyond what is visibly obvious.

Do not use all three by default. Attribute quotations and do not present a
paraphrase as a quote.

## Produce the Artifact

Match the production method to the output:

- Build exact diagrams, cards, and type-led compositions as vector or native
  layout artifacts.
- Generate raster illustrations when the concept needs a physical scene,
  texture, or expressive material treatment.
- Create each carousel or storyboard frame at a consistent ratio and shared
  visual system.
- Adapt line length, safe areas, pacing, and reveal behavior to the actual
  delivery platform.
- Include dimensions, safe areas, palette, typography behavior, object
  positions, frame transitions, and exact copy in a production brief.
- Continue through rendering and visual inspection when the user requested a
  finished artifact. Do not stop at a prompt unless rendering is unavailable or
  the user requested only the prompt.

## Run the Clarity Cut

Inspect the result at full size and thumbnail size. Revise until every answer is
yes:

- Can a viewer state the primary relationship in one sentence?
- Does the eye know where to look first and where to move next?
- Is every object carrying meaning?
- Could one label, shape, frame, or color be removed?
- Does the metaphor remain faithful under scrutiny?
- What would the strongest skeptical viewer say the visual gets wrong?
- Does the language add meaning instead of duplicating the picture?
- Can the intended audience locate its own situation, choice, or change in it?
- Is the composition original rather than a disguised reconstruction?
- Does the result still work in the requested medium and context?

Deliver the artifact with a concise statement of the central idea. Include
production notes only when they help the user edit, hand off, or reproduce it.
