---
name: frontend-design
description: "Design and implement distinctive, production-ready interfaces for HTML-first, server-rendered apps. Default stack: HTML, HTMX, Alpine.js, Tailwind CSS v4, daisyUI v5, minimal vanilla JS. Do not introduce React, Vue, Svelte, or replace daisyUI/Tailwind unless the user explicitly requests it."
---

# Frontend Design Skill

Design and implement memorable frontend interfaces with a clear, intentional aesthetic. The output must be real, working code — not just mood boards. This skill is about **design thinking + execution**: every visual choice should be rooted in purpose and context.

## Default Stack (Required)

Unless the user explicitly asks otherwise, build with:

- Semantic HTML
- Server-rendered templates (Jinja2 / equivalent)
- HTMX for server communication
- Alpine.js for ephemeral UI state
- Tailwind CSS v4 for utilities
- **daisyUI v5 for component classes and theming** (the default visual layer)
- Minimal vanilla JS for small glue only

Do not introduce React, Vue, Svelte, SPA routers, or replace daisyUI with hand-authored CSS unless the user explicitly requests it.

## Companion Skills

- For HTMX/Alpine interaction patterns → load `htmx-alpine`
- For first-time project setup (install Tailwind+daisyUI, wire FastAPI build) → load `setup-daisyui-tailwind-fastapi`

## Default Styling System: daisyUI + Tailwind

Use daisyUI v5 component classes (`btn`, `card`, `input`, `navbar`, `drawer`, `modal`, `alert`, `badge`, `menu`, `tabs`, `loading`, etc.) as the baseline.

Layer on Tailwind utilities only when:
- daisyUI has no component for that need
- you need fine spacing/layout adjustments
- you need responsive overrides

Color and theme:
- Use daisyUI semantic colors: `primary`, `secondary`, `accent`, `neutral`, `base-100/200/300`, `info`, `success`, `warning`, `error`
- Pick or customize a daisyUI theme — do not hand-roll CSS variables for colors
- Use `data-theme` on `<html>` to switch themes

Aesthetic direction still matters: pick a daisyUI theme that fits the vibe, customize it, and apply your typography/scale/motion on top.

## When to Use

Use this skill when the user wants to:
- Create a new web page, landing page, dashboard, or app UI
- Design or redesign frontend components or screens
- Improve typography, layout, color, motion, or overall visual polish
- Convert a concept or brief into a high‑fidelity, coded interface

## Inputs to Gather (or Assume)

Before coding, identify:
- **Purpose & audience**: What problem does this UI solve? Who uses it?
- **Brand/voice**: Any reference brands, tone, or visual inspiration?
- **Technical constraints**: Framework, library, CSS strategy, accessibility, performance
- **Content constraints**: Required copy, assets, data, features

If the user did not provide this, ask **2–4 targeted questions**, or state reasonable assumptions in a short preface.

## Design Thinking (Required)

Commit to a **single, bold aesthetic direction**. Name it and execute it consistently. Examples:
- Brutalist / raw / utilitarian
- Editorial / magazine / typographic
- Luxury / refined / minimal
- Retro‑futuristic / cyber / neon
- Art‑deco / geometric / ornamental
- Handcrafted / organic / textured

**Avoid generic AI aesthetics.** No “default” fonts, color schemes, or stock layouts.

Before writing code, define the system:
1. **Visual direction** — one sentence that describes the vibe
2. **Differentiator** — what should be memorable about this UI?
3. **Typography system** — display + body fonts, scale, weight, casing
4. **Color system** — dominant, accent, neutral; define as CSS variables
5. **Layout strategy** — grid rhythm, spacing scale, hierarchy plan
6. **Motion strategy** — 1–2 meaningful interaction moments

If the user wants code only, skip the explanation but still follow this internally.

## Implementation Principles

- **Working code**: HTML/CSS/JS or framework code that runs as‑is
- **Semantic & accessible**: headings, labels, focus states, keyboard nav
- **Responsive**: fluid layouts, breakpoints, responsive typography
- **Tokenized styling**: CSS variables for colors, spacing, radii, shadows
- **Modern layout**: prefer CSS Grid/Flex, avoid brittle positioning hacks

## Aesthetic Guidelines

### Typography
- Typography should define the voice of the design
- Avoid default fonts (Inter, Roboto, Arial, system stacks)
- Use a **distinct display font** + a **refined body font**
- Implement a clear hierarchy (size, weight, spacing, casing)

### Color & Theme
- Commit to a palette with a strong point‑of‑view
- Avoid timid, overused gradients (e.g., purple‑to‑pink on white)
- Use contrast intentionally and check legibility

### Composition & Layout
- Encourage asymmetry, scale contrast, overlap, or grid breaks
- Use negative space deliberately (or controlled density if maximalist)
- Create visual rhythm and hierarchy through spacing and alignment

### Detail & Atmosphere
- Add texture or depth when appropriate (noise, grain, subtle patterns)
- Use shadows/glows only when they serve the concept
- Consider unique borders, masks, or clip‑paths for distinct shapes

### Motion & Interaction
- Use motion sparingly but meaningfully
- Favor one standout interaction over many tiny ones
- Honor `prefers-reduced-motion`

## Avoid

- Replacing daisyUI/Tailwind with vanilla CSS unless the user asks
- React/Vue/Svelte unless the user asks
- Utility soup when a daisyUI component class covers it
- Default Tailwind palette when daisyUI semantic tokens (`primary`, `base-100`, etc.) fit
- Cookie‑cutter hero + 3 card layouts
- Generic gradients and default font choices
- Unmotivated decorative elements
- Overly flat, characterless component libraries

## Deliverables

- Provide full code with file names or component boundaries
- Make customization easy with CSS variables or config objects
- If assets are needed, provide inline SVGs or generative CSS patterns

## Quality Checklist (Self‑validate)

- Aesthetic direction is unmistakable
- Typography feels intentional and expressive
- Layout and spacing are consistent and purposeful
- Color palette feels cohesive and legible
- Interactions enhance the experience without clutter
- Code runs as provided and is production‑ready

**Remember:** a design is only as strong as its commitment. Choose a direction and execute it relentlessly.
