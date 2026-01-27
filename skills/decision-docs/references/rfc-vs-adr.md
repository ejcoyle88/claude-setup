# RFC vs ADR: When to Use Which

## Quick Decision Tree

```
Is this decision reversible without major cost?
├─ Yes → ADR (document it quickly, move on)
└─ No → Does it affect multiple teams or external parties?
    ├─ Yes → RFC (get broad input first)
    └─ No → ADR (team decision, document for future)
```

## RFC: Request for Comments

**Purpose**: Propose significant changes that need organization-wide review and consensus.

**Use when**:
- Decision affects multiple teams or services
- Requires input from domain experts outside your team
- Changes public APIs or contracts
- Has broad architectural implications
- Involves significant resource commitment
- Difficult to reverse once implemented

**Examples**:
- Migrating from SQLite to PostgreSQL (affects all services)
- Implementing OIDC provider (public API)
- Adopting a new deployment architecture
- Changing authentication system (affects all users)
- Multi-month infrastructure projects

**Process**:
- Write comprehensive RFC with alternatives evaluated
- Share with relevant stakeholders
- Iterate based on feedback
- Track "Seen By" section for accountability
- Update "Errata" section as implementation evolves

**Time investment**: Hours to days of writing; days to weeks of review cycle.

## ADR: Architectural Decision Record

**Purpose**: Document decisions made so future maintainers understand why things are the way they are.

**Use when**:
- Decision is primarily within your team's scope
- You've made a choice and want to record the rationale
- Quick documentation is more valuable than lengthy debate
- Alternatives exist but decision is clear
- You want to prevent future "why did we do this?" questions

**Examples**:
- Choosing Axum over other Rust web frameworks
- Using SQLite for local development
- Structuring test fixtures a certain way
- Selecting a date formatting library
- Organizing module boundaries

**Process**:
- Write brief ADR (< 30 minutes)
- Share with team if desired (optional)
- Commit and move on
- Update if circumstances change significantly

**Time investment**: 15-30 minutes of writing; minimal review needed.

## Gray Areas

Some decisions could go either way. Consider:

### "We're rewriting the authentication system"

- **RFC if**: Changes affect other teams, public API, or requires significant resources
- **ADR if**: Internal refactoring with same external behavior, team-scoped work

### "We're adopting a new testing framework"

- **RFC if**: Would require all teams to change their approach
- **ADR if**: Just for your team's services

### "We're changing the database schema"

- **RFC if**: Breaking change affecting multiple services
- **ADR if**: Additive change or isolated to one service

## When in Doubt

**Start with ADR if**:
- You can ship it independently
- Rollback is feasible
- Scope is contained to your team
- You need to move quickly

**Escalate to RFC if**:
- Others raise concerns during ADR review
- You discover broader implications
- Reversing would be costly

## Anti-patterns

❌ **Don't use RFC for**:
- Decisions that are already made (use ADR to document)
- Obvious choices (no need to document)
- Purely internal implementation details

❌ **Don't use ADR for**:
- Changes that need external input (use RFC)
- Proposals that aren't yet decisions
- Major breaking changes without consensus

## Template Comparison

### RFC Template (comprehensive)
- Problem statement with impact
- Proposed solution with details
- Prior art / alternatives analysis
- Performance implications
- Backward compatibility plan
- FAQ section
- Stakeholder tracking

### ADR Template (lightweight)
- Context (why now?)
- Decision (what we chose)
- Consequences (trade-offs)

**Rule of thumb**: If filling out the RFC template feels like overkill, use an ADR.
