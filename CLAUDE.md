
# Project Rule: Graphify First

Always use Graphify before reading or editing files.

Before any task:
- Query the project graph first.
- Identify only the required files.
- Do not scan the whole codebase.

After every code change:
- Update Graphify automatically.
- Re-check affected dependencies.
- Summarize changed files and impacted modules.

Never read large files unless Graphify shows they are directly relevant.


# Tradie Job Manager — Project Instructions

## Design System
All UI, icons, components, and styling MUST follow `.claude/styling.md` exactly. Read it before writing any UI code.

Key rules:
- **Icons**: Iconsax style — linear/outline, rounded, consistent stroke width, icon on every major module
- **Colours**: Deep navy/charcoal, electric blue (primary), safety orange (compliance), green (paid), red (overdue), soft grey backgrounds, white cards
- **Typography**: Clean modern sans-serif, strong headings, readable tables, large mobile buttons
- **Web layout**: Left sidebar, top search bar, card-based dashboard, slide-over panels, modal forms
- **Mobile layout**: Bottom nav, large action buttons, swipe cards, floating check-in button
- **Motion**: Smooth micro-interactions, hover lift, card reveal, soft transitions — no excessive animation
- **Shapes**: Soft blobs, rounded geometric cards, glass-style panels, avoid plain rectangles
- **Theme**: Light-first with dark mode support
- **Stack**: Flutter (mobile + web)

Never use generic AI SaaS aesthetics. This is a premium Australian tradie business tool.

## graphify

This project has a graphify knowledge graph at graphify-out/.

Rules:
- Before answering architecture or codebase questions, read graphify-out/GRAPH_REPORT.md for god nodes and community structure
- If graphify-out/wiki/index.md exists, navigate it instead of reading raw files
- After modifying code files in this session, run `graphify update .` to keep the graph current (AST-only, no API cost)
