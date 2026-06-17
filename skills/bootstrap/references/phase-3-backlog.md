# Phase 3 — Backlog generation

Generate structured epics, stories, and tasks. Hold these in memory for the provision step.

### Epic format
```
Epic: [E1] [Name]
Priority: P0 (MVP) | P1 (post-MVP) | P2 (future)
Stories:
  - [E1-S1] As a [persona], I want [capability], so that [value]
    Acceptance criteria:
      - [ ] [Testable criterion]
      - [ ] [Testable criterion]
    Story points: [1/2/3/5/8/13]
    Tasks:
      - [ ] [Implementation task]
      - [ ] [Implementation task]
      - [ ] Write tests for [feature]
```

### Standard epics (include in every project)
- **E0: Project setup** — Seed repo clone, env configuration, local dev working, CI green (P0, pre-done by seed — mark complete)
- **E1: Auth + user management** — Sign up, sign in, session handling, route protection (P0)
- **E-LAST: Deployment** — Production env vars, domain, SSL, monitoring, DO App Platform config (P0)

### Story point scale
1=trivial, 2=small, 3=medium-small, 5=medium, 8=large, 13=very large, 21=must split
