---
name: adversary
description: Use WHENEVER the user asks to review, audit, verify, critique, double-check, or "find problems with" ANY reasoning-bearing document. This explicitly includes: implementation plans, design docs, PR review drafts, code review findings, exploration answers, bug-fix proposals, architectural recommendations, AI-instruction files (CLAUDE.md, AGENTS.md), workspace/project guidance files, architecture decision records (ADRs), RFCs, spec documents, runbooks, README files containing claims, CONTRIBUTING guides, CHANGELOG entries, postmortems, or any document containing decisions, claims, or reasoning the user wants double-checked. The user may name the document by absolute path, by filename, by relative location ("the workspace's top-level instructions", "the design doc we just discussed", "my CLAUDE.md"), or by gesturing at content they pasted. Trigger phrases include "review/audit/verify/critique X", "audit the X file", "adversarial review of X", "find problems with X", "tear this apart", "double-check X", "what's wrong with X", "run adversary on X". The intent test for whether to trigger: is the user asking to check that the document's reasoning, claims, or correctness is sound (TRIGGER) versus asking for explanation, summarization, style/formatting feedback, translation, or non-adversarial code review (DON'T TRIGGER)? Identifies the artifact path from conversation context and recommends the `/adversary:review` slash command for the user to run.
---

<CRITICAL>
The adversary dispatcher does exactly THREE things:

1. Identify the artifact path from conversation context.
2. Resolve it to an absolute path.
3. Emit the line `Recommended: /adversary:review <absolute-path>` so the user can run it.

Do NOT run the review. Do NOT call Bash with `pipeline.sh`. Do NOT call the Skill() tool to invoke another skill. The 3-subprocess pipeline only fires when the user types the slash command — that is where the permission grant lives. Bypassing it triggers a permission prompt on every invocation.
</CRITICAL>

## When to use — TRIGGER

Trigger when the user asks for adversarial review of a reasoning-bearing artifact. Phrases that DO trigger:

- "review the plan" / "review this design" / "review my findings"
- "audit the proposal" / "audit /path/to/file"
- "verify the analysis" / "verify these findings"
- "critique my approach" / "critique this"
- "adversarial review of X"
- "tear this apart" / "find problems with this" / "what's wrong with this"
- "double-check the design" / "check for issues with this plan"
- "run adversary on X" (explicit invocation)

## When NOT to use — DO NOT TRIGGER on these

These look like review requests but are NOT adversarial-review intent. Do not trigger:

- "explain this design" → explanation, not critique. Read the file and explain.
- "summarize the plan" → summarization.
- "what does this code do?" → comprehension question.
- "code review this PR" / "review the diff" without adversarial framing → that's a normal code review, not the adversary pipeline. (If the user says "ADVERSARIAL code review" or "critical review" of a PR, then YES.)
- "format/fix style/clean up the docs" → style work.
- "translate this to Spanish" → translation.
- "describe what's in this file" → description.
- "did I miss anything?" without an artifact in scope → too vague; ask what artifact.
- "review my writing style" → copy/style review, not reasoning review.

**The test:** is the user asking for a *check that the artifact's reasoning is sound* (trigger), or asking for something else (don't trigger)? If unclear, ASK before triggering.

## When NOT to use — TRIVIAL artifacts

Adversarial review is expensive (three full Claude subprocesses, several minutes, real tokens). Do not trigger on trivial inputs even if the user uses a trigger phrase:

- A one-line answer.
- A directory listing.
- A `.gitignore`, lockfile, or other generated boilerplate.
- A < 20-line config file with no reasoning content.
- A simple bug fix patch that's literally one line.

If the artifact has < 20 lines of substantive reasoning, ask the user "this is pretty short — are you sure you want to run the full adversary pipeline on it?" before recommending.

## File identification — STRICT priority order

Work through these in order. **STOP at the first confident match. Do not skip ahead.**

### Step 1 — most recent Edit/Write in this session

Scan backward through the session's tool-call history for the latest `Edit` or `Write` tool call.

**MATCH if:**
- An Edit/Write occurred in this session, AND
- The user's request plausibly refers to that file (user said "review THIS plan" with a plan file as the most recent Edit/Write), AND
- The Write/Edit happened recently — within the last ~5 user turns, not 50 turns ago.

**DO NOT MATCH if:**
- The most recent Write was something unrelated (e.g., CHANGELOG entry, settings file) and the user named a different artifact ("review the design" but most recent Write was the CHANGELOG → go to Step 2).
- The most recent Edit was a one-line fix to a file that isn't the artifact being discussed.

### Step 2 — explicit path in the user's recent messages

Scan the last few user messages for an absolute or relative file path.

**MATCH if exactly one path appears**, e.g. user said "audit /tmp/colleague-plan.md" — use that path verbatim.

**DO NOT MATCH if:**
- Multiple paths are mentioned and it's unclear which one — go to Step 4.
- The user mentions a filename without a directory (just "design.md") and there are multiple candidates with that name in the project — go to Step 4.

### Step 3 — inline content paste

If the user pasted the artifact content directly into chat (not a path) and asked for review on it:

1. Write the pasted content to `/tmp/adversary-paste-$(date +%s).md` via the Write tool.
2. Recommend the slash command using the absolute path of the new file.

### Step 4 — ambiguous → AskUserQuestion

If multiple files plausibly match, OR if the most recent Write doesn't match the artifact-noun the user used, OR if multiple filename-only references exist:

**USE the `AskUserQuestion` tool** with the candidate paths as options. Do not guess. Do not pick the first one. Do not invent.

### Step 5 — no candidate → ask directly

If nothing matches at all:

**Ask the user**: "Which file is the artifact you'd like reviewed? Paste the absolute path."

### Path resolution

**ALWAYS resolve to an absolute path before emitting the recommendation.** The slash command resolves relative paths against the user's cwd at run time, which may not match the dispatcher's cwd. A relative path that works in this context may break in theirs.

If the user provided a relative path (`./design.md`), expand it against the cwd they appear to be working in (check recent tool calls for clues, or use `pwd` via Bash).

## What to emit — EXACT FORMAT

The user must be able to run the output by hitting enter. Emit the slash command literally, in a code block so it's runnable:

```
Recommended: /adversary:review /absolute/path/to/artifact
```

At most one sentence of context if it disambiguates ("this is the artifact at /path/to/..."). No more.

**WRONG:**
> "I think you should run the adversary review on the design doc. The command would be something like `/adversary:review` followed by the path to your design document."

**RIGHT:**
> `Recommended: /adversary:review /path/to/projects/foo/design.md`

The wrong version is prose; the right version is a runnable command. The user should be able to copy-paste or visually-glance-and-type without parsing a sentence.

## Anti-patterns — DO NOT DO THESE

Real failure modes to avoid:

### Anti-pattern 1: Running pipeline.sh directly

```
# WRONG
Bash(command="bash ${CLAUDE_PLUGIN_ROOT}/scripts/pipeline.sh /path/to/artifact")
```

This bypasses the slash command's permission grant. It will fail (no pre-grant for this path under this skill), AND if it somehow succeeds, future runs will hit a prompt loop on every invocation. **The slash command is the ONLY entry point.**

### Anti-pattern 2: Inventing a path

User: "review the design"
*(No recent Write, no path in conversation.)*

**WRONG:** Emit `Recommended: /adversary:review /path/to/projects/design.md` (guessing).
**RIGHT:** Use AskUserQuestion to ask for the path.

### Anti-pattern 3: Picking a recent Write when the user named a different artifact

The most recent Write is `CHANGELOG.md`. User says "review the design."

**WRONG:** Emit `Recommended: /adversary:review /path/to/CHANGELOG.md`.
**RIGHT:** AskUserQuestion — "Did you mean the design file? No design file appears in this session — paste the path?"

### Anti-pattern 4: Emitting a relative path

User: "review ./plan.md"

**WRONG:** Emit `Recommended: /adversary:review ./plan.md` (relative path will resolve against the user's cwd, not the dispatcher's, possibly breaking).
**RIGHT:** Resolve to absolute first: `Recommended: /adversary:review /path/to/projects/foo/plan.md`.

### Anti-pattern 5: Triggering on a non-adversarial request

User: "explain the design doc"

**WRONG:** Trigger this skill, emit `Recommended: /adversary:review ...`.
**RIGHT:** Don't trigger. Read the file and explain it.

### Anti-pattern 6: Triggering on a trivial artifact

User: (writes a one-line shell alias) "review this"

**WRONG:** Emit `Recommended: /adversary:review ...` for a 1-line alias.
**RIGHT:** "This is a single line — no real reasoning to critique. Do you want me to run the adversary pipeline on it anyway, or is something else off?"

### Anti-pattern 7: Burying the recommendation in prose

**WRONG:**
> "Great work on the design! I think this looks solid overall, but I agree it might be worth a more thorough review. You could try running the adversary plugin on it — the command would be `/adversary:review` followed by the file path."

**RIGHT:**
> `Recommended: /adversary:review /path/to/projects/foo/design.md`

Be terse and runnable.

### Anti-pattern 8: Chaining into Skill() to re-invoke the dispatcher

**WRONG:** Call `Skill('adversary:adversary')` from within this skill body.
**RIGHT:** This skill IS the dispatcher. Just emit the recommendation.

## Examples — GOOD triggers and outputs

**Example A:**
> **User:** "I just finished the design doc — can you review it?"
> *(Most recent Write: `/path/to/projects/foo/design.md`. Match Step 1.)*
> **Emit:**
> ```
> Recommended: /adversary:review /path/to/projects/foo/design.md
> ```

**Example B:**
> **User:** "audit /tmp/colleague-plan.md"
> *(Path explicit. Match Step 2.)*
> **Emit:**
> ```
> Recommended: /adversary:review /tmp/colleague-plan.md
> ```

**Example B2 — referenced by description, not path:**
> **User:** "audit the workspace's top-level instructions, meaning the CLAUDE.md"
> *(User names the file by description AND clarifies the filename. CLAUDE.md is a reasoning-bearing instruction file — IN SCOPE. Match Step 2 via the filename hint; resolve to absolute by looking at current cwd.)*
> **Emit:**
> ```
> Recommended: /adversary:review /path/to/project/CLAUDE.md
> ```
> Do NOT just read and explain the file. The verb "audit" plus a substantive instruction document means TRIGGER, not narrate.

**Example B3 — AI-instruction file at plugin level:**
> **User:** "verify the agent description for the adversary skill"
> *(Refers to the skill's own description block — a reasoning-bearing instruction file. IN SCOPE. Match Step 2 via the contextual reference.)*
> **Emit:**
> ```
> Recommended: /adversary:review /path/to/plugins/adversary/skills/adversary/SKILL.md
> ```

**Example C:**
> **User:** *(pastes 200 lines of a design proposal)* "go over this"
> *(Inline paste. Match Step 3.)*
> **Action:**
> 1. `Write(file_path="/tmp/adversary-paste-1779190000.md", content=<paste>)`
> 2. Emit:
> ```
> Recommended: /adversary:review /tmp/adversary-paste-1779190000.md
> ```

**Example D — ambiguous:**
> **User:** "verify the plan"
> *(Most recent Writes: `plan.md`, `CHANGELOG.md`, `README.md`. Multiple candidates.)*
> **Action:** Use `AskUserQuestion` with the three paths as options. Do NOT guess.

**Example E — no candidate:**
> **User:** "review the findings" *(no Edit/Write in session; no path in messages)*
> **Action:** Use `AskUserQuestion`: "Which file holds the findings? Paste the absolute path."

## Examples — when NOT to trigger

**Anti-example A:**
> **User:** "explain the design doc to me"
> *(Trigger phrase missing — "explain" is not adversarial.)*
> **Action:** Don't trigger. Read the file, explain it in chat.

**Anti-example B:**
> **User:** "fix the typos in plan.md"
> *(Style work, not adversarial review.)*
> **Action:** Don't trigger. Edit the file directly.

**Anti-example C:**
> **User:** *(just had a 30-message debugging session)* "review this"
> *(No clear artifact — "this" is ambiguous; could be the debugging conversation, the patch, the test output.)*
> **Action:** Don't auto-trigger. Ask: "Which artifact? The patch, the test results, or the debugging notes?"

**Anti-example D:**
> **User:** "review my code style in the new file"
> *(Style review, not reasoning review.)*
> **Action:** Don't trigger. Do a normal style read.

## Self-check before emitting

Before emitting `Recommended: /adversary:review ...`, verify:

1. Did the user use an adversarial framing (review / audit / verify / critique / find problems / tear apart)? If NO → don't trigger.
2. Is the artifact a substantive reasoning document (plan, design, findings, proposal)? If trivial → confirm with the user before recommending.
3. Is the path absolute? If relative → resolve first.
4. Is the file the user means clear? If ambiguous → AskUserQuestion.
5. Is the recommendation a runnable line, not buried in prose? If buried → reformat.

If any answer is "no" or "not sure," fix it before emitting.
