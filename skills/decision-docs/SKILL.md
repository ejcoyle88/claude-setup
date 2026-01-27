---
name: decision-docs
description: "Create and improve RFC (Request for Comment) and ADR (Architectural Decision Record) documents. Use when users need to document technical decisions or architectural changes. Supports: (1) Writing new RFCs for organization-wide technical proposals requiring review, (2) Writing new ADRs for team-level decision documentation, (3) Helping users choose between RFC vs ADR format, (4) Filling or improving specific sections like Prior Art or Consequences, (5) Reviewing and improving existing RFC/ADR drafts. Triggers include requests like 'write an RFC', 'create an ADR', 'document this decision', 'help with the consequences section', or 'should this be an RFC or ADR?'."
---

# Decision Documentation

## Overview

This skill helps create and improve RFC (Request for Comment) and ADR (Architectural Decision Record) documents for technical decisions.

**Document Types**:
- **RFC**: Organization-wide proposals needing broad review (e.g., major migrations, public API changes)
- **ADR**: Team-level decision records for future reference (e.g., library choices, internal patterns)

## Workflow

### 1. Determine Document Type

If the user hasn't specified RFC vs ADR, read `references/rfc-vs-adr.md` to help them choose.

**Quick guidance**:
- **RFC**: Affects multiple teams, hard to reverse, needs consensus
- **ADR**: Team-scoped, relatively reversible, documenting a made decision

### 2. Create or Locate Document

**For new documents**, use the script:

```bash
python scripts/create_doc.py rfc "title of the decision"
python scripts/create_doc.py adr "title of the decision"
```

The script creates a file with date-based naming (e.g., `2024-01-15-migration-to-postgres.md`) in the appropriate directory (`docs/rfcs/` or `docs/adrs/`) using the project's template.

**For existing documents**, locate the file the user wants to work on.

### 3. Fill or Improve Content

#### Full Document Creation

When creating a full RFC or ADR from scratch:

1. **Start with key sections first**:
   - RFC: Problem → Solution → Prior Art
   - ADR: Context → Decision → Consequences

2. **Keep it concise**: See `references/writing-guide.md` for strategies on brevity

3. **Focus on trade-offs**: Especially important for Consequences and Prior Art sections

4. **Iterate**: Start with draft, refine based on what matters most

#### Working on Specific Sections

When user asks to fill or improve a specific section:

1. **Read `references/writing-guide.md`** for section-specific guidance
2. **Focus on that section's goal**:
   - Problem: Convince it's worth solving
   - Solution: Right level of abstraction
   - Prior Art: Show alternatives considered
   - Consequences: Both benefits and drawbacks
3. **Be specific, not comprehensive**

#### Quick ADR Creation

For straightforward decisions, create minimal but complete ADR:

1. Context: 2-4 sentences on what prompted this
2. Decision: 1-2 sentences stating the choice
3. Consequences: 3-5 bullet points on trade-offs

Total time: ~15 minutes

### 4. Review and Refine

Use the checklist from `references/writing-guide.md`:

- Can someone unfamiliar understand the problem?
- Is the decision clear and unambiguous?
- Are alternatives explained?
- Do consequences include drawbacks, not just benefits?
- Could you cut 20% of words without losing meaning?

## Key Principles

1. **Concise over comprehensive**: Shorter documents get read
2. **Specific over vague**: "Reduces build time from 10min to 2min" not "improves developer experience"
3. **Trade-offs over benefits**: Every decision has downsides
4. **Examples over explanations**: Show, don't tell

## Reference Materials

Load these as needed:

- **`references/rfc-vs-adr.md`**: Decision tree for choosing document type; when to escalate ADR to RFC
- **`references/writing-guide.md`**: Detailed guidance on keeping documents concise, writing effective consequences, and section-by-section tips

## Common Scenarios

**"Write an RFC for migrating to PostgreSQL"**:
1. Run `python scripts/create_doc.py rfc "migration to postgres"`
2. Read `references/writing-guide.md` for RFC guidance
3. Fill out: Problem (why migrate), Solution (migration approach), Prior Art (why not other DBs), Performance Impact, Backward Compatibility

**"Create an ADR for using Rust"**:
1. Run `python scripts/create_doc.py adr "use rust for backend"`
2. Quick fill: Context (need for performance + safety), Decision (Rust for backend services), Consequences (memory safety benefits vs steeper learning curve)

**"Help me write the consequences section"**:
1. Read `references/writing-guide.md` → "Writing Effective Consequences"
2. Structure: What becomes easier, What becomes harder, What stays the same
3. Be specific with trade-offs

**"Should this be an RFC or ADR?"**:
1. Read `references/rfc-vs-adr.md`
2. Ask: Does it affect other teams? Is it hard to reverse? Does it need external input?
3. Guide user to appropriate format

## Script Usage

The `scripts/create_doc.py` script should be run from the project root:

```bash
# Create an RFC
python scripts/create_doc.py rfc "descriptive title here"

# Create an ADR
python scripts/create_doc.py adr "descriptive title here"
```

The script:
- Generates date-based filename (YYYY-MM-DD-slug.md)
- Creates file in correct directory (docs/rfcs/ or docs/adrs/)
- Copies appropriate template content
- Reports success and next steps

**When to use the script**:
- Creating new documents from scratch
- User wants proper file naming/structure

**When to skip the script**:
- User already has a file they want to work on
- Only helping with specific sections of existing document
- User prefers to create file manually
