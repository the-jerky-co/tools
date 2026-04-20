#!/bin/sh
# ============================================================
#  build-index.sh
#  Auto-generates index.html from the repo's folder/file structure.
#  Called by watch-and-pr.sh after each file copy.
#  Also run this manually to regenerate locally.
#  POSIX sh compatible — no bash 4+ features (works on Synology DSM).
# ============================================================

REPO_DIR="${1:-$(pwd)}"
OUTPUT="$REPO_DIR/index.html"
TMPDIR_BASE="${TMPDIR:-/tmp}/build-index-$$"
mkdir -p "$TMPDIR_BASE"

# Collect all HTML tools, excluding Synology system dirs and repo internals
find "$REPO_DIR" -name "*.html" \
  ! -name "index.html" \
  ! -path "*/scripts/*" \
  ! -path "*/.git*" \
  ! -path "*/#recycle*" \
  ! -path "*/@eaDir*" \
  ! -path "*/@tmp*" \
  | sort > "$TMPDIR_BASE/files.txt"

# Build one temp file per category using awk to group files
awk -v repo="$REPO_DIR/" '
{
  rel = $0
  sub(repo, "", rel)
  n = split(rel, parts, "/")
  if (n < 2) next
  cat = parts[1]
  filename = parts[n]
  sub(/\.html$/, "", filename)
  # humanise: replace -_ with space
  gsub(/[-_]/, " ", filename)
  label = filename
  print cat "\t" rel "\t" label
}
' "$TMPDIR_BASE/files.txt" | sort > "$TMPDIR_BASE/entries.txt"

# Get unique sorted categories
cut -f1 "$TMPDIR_BASE/entries.txt" | sort -u > "$TMPDIR_BASE/cats.txt"

CATEGORY_BLOCKS=""

while IFS= read -r CAT; do
  [ -z "$CAT" ] && continue

  # Title-case the category name
  CAT_LABEL=$(echo "$CAT" | sed 's/[-_]/ /g' | awk '{
    for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)
    print
  }')

  # Build card HTML for all files in this category
  CARDS=""
  while IFS='	' read -r ENTRY_CAT REL LABEL; do
    [ "$ENTRY_CAT" = "$CAT" ] || continue
    # Title-case each word of the label
    TC_LABEL=$(echo "$LABEL" | awk '{
      for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)
      print
    }')
    CARDS="${CARDS}<a href=\"${REL}\" class=\"tool-card\" target=\"_blank\"><span class=\"tool-name\">${TC_LABEL}</span><span class=\"tool-arrow\">↗</span></a>"
  done < "$TMPDIR_BASE/entries.txt"

  [ -z "$CARDS" ] && continue

  CATEGORY_BLOCKS="${CATEGORY_BLOCKS}
    <section class=\"category\">
      <h2 class=\"category-title\">
        <span class=\"category-label\">${CAT_LABEL}</span>
        <span class=\"category-line\"></span>
      </h2>
      <div class=\"tool-grid\">${CARDS}</div>
    </section>"
done < "$TMPDIR_BASE/cats.txt"

rm -rf "$TMPDIR_BASE"

# If no tools yet, show placeholder
if [ -z "$CATEGORY_BLOCKS" ]; then
  CATEGORY_BLOCKS='<p class="empty">No tools published yet. Drop an HTML file into a department folder on the NAS to get started.</p>'
fi

BUILT_DATE=$(date '+%d %b %Y, %H:%M')

cat > "$OUTPUT" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Team Tools</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=DM+Mono:wght@400;500&family=Syne:wght@400;600;800&display=swap" rel="stylesheet">
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    :root {
      --bg: #0d0d0d;
      --surface: #161616;
      --border: #2a2a2a;
      --accent: #c8f135;
      --text: #e8e8e8;
      --muted: #666;
      --card-hover: #1e1e1e;
    }

    body {
      background: var(--bg);
      color: var(--text);
      font-family: 'Syne', sans-serif;
      min-height: 100vh;
      padding: 0 0 80px;
    }

    /* ── Header ── */
    header {
      border-bottom: 1px solid var(--border);
      padding: 48px 64px 40px;
      display: flex;
      align-items: flex-end;
      justify-content: space-between;
      gap: 24px;
      flex-wrap: wrap;
    }

    .site-title {
      font-size: clamp(2.5rem, 5vw, 4rem);
      font-weight: 800;
      letter-spacing: -0.03em;
      line-height: 1;
    }

    .site-title span {
      color: var(--accent);
    }

    .site-meta {
      font-family: 'DM Mono', monospace;
      font-size: 0.75rem;
      color: var(--muted);
      text-align: right;
      line-height: 1.8;
    }

    /* ── Layout ── */
    main {
      max-width: 1200px;
      margin: 0 auto;
      padding: 64px 64px 0;
    }

    /* ── Category ── */
    .category {
      margin-bottom: 56px;
    }

    .category-title {
      display: flex;
      align-items: center;
      gap: 16px;
      margin-bottom: 20px;
      font-size: 0.7rem;
      font-family: 'DM Mono', monospace;
      font-weight: 500;
      text-transform: uppercase;
      letter-spacing: 0.15em;
      color: var(--muted);
    }

    .category-line {
      flex: 1;
      height: 1px;
      background: var(--border);
    }

    /* ── Tool Grid ── */
    .tool-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
      gap: 1px;
      background: var(--border);
      border: 1px solid var(--border);
    }

    .tool-card {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 20px 24px;
      background: var(--surface);
      text-decoration: none;
      color: var(--text);
      transition: background 0.15s, color 0.15s;
      gap: 12px;
    }

    .tool-card:hover {
      background: var(--card-hover);
      color: var(--accent);
    }

    .tool-name {
      font-size: 0.95rem;
      font-weight: 600;
      letter-spacing: -0.01em;
    }

    .tool-arrow {
      font-size: 1rem;
      opacity: 0.4;
      transition: opacity 0.15s, transform 0.15s;
      flex-shrink: 0;
    }

    .tool-card:hover .tool-arrow {
      opacity: 1;
      transform: translate(2px, -2px);
    }

    .empty {
      color: var(--muted);
      font-family: 'DM Mono', monospace;
      font-size: 0.85rem;
      padding: 32px 0;
    }

    /* ── Footer ── */
    footer {
      margin-top: 80px;
      padding: 0 64px;
      font-family: 'DM Mono', monospace;
      font-size: 0.7rem;
      color: var(--muted);
      display: flex;
      gap: 8px;
      align-items: center;
    }

    footer::before {
      content: '';
      display: block;
      width: 8px;
      height: 8px;
      border-radius: 50%;
      background: var(--accent);
    }

    @media (max-width: 640px) {
      header, main, footer { padding-left: 24px; padding-right: 24px; }
      header { padding-top: 32px; }
    }
  </style>
</head>
<body>

  <header>
    <h1 class="site-title">Team<span>Tools</span></h1>
    <div class="site-meta">
      Internal use only<br>
      Updated $BUILT_DATE
    </div>
  </header>

  <main>
    $CATEGORY_BLOCKS
  </main>

  <footer>Auto-generated from repository structure</footer>

</body>
</html>
HTML

echo "Index built → $OUTPUT"
