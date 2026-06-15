#!/bin/bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARKDOWN_DIR="$ROOT_DIR/user/markdown"
PORT="${PORT:-9000}"

if [ ! -d "$MARKDOWN_DIR" ]; then
    echo "Error: $MARKDOWN_DIR does not exist."
    exit 1
fi

# Prefer grip if available (GitHub-flavored rendering)
if command -v grip &>/dev/null; then
    echo "Serving $MARKDOWN_DIR with grip on http://localhost:$PORT"
    exec grip "$MARKDOWN_DIR" "$PORT"
fi

# Fall back to a Python server with client-side Markdown rendering
if ! command -v python3 &>/dev/null; then
    echo "Error: python3 not found. Install python3 or grip to use this server."
    exit 1
fi

echo "Serving $MARKDOWN_DIR on http://localhost:$PORT"
echo "Press Ctrl+C to stop."

python3 - "$MARKDOWN_DIR" "$PORT" <<'PYEOF'
import sys, os, html, urllib.parse, http.server

SERVE_DIR = sys.argv[1]
PORT = int(sys.argv[2])

INDEX_TMPL = """\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Markdown Browser</title>
<style>
  body {{ font-family: sans-serif; max-width: 860px; margin: 40px auto; padding: 0 20px; color: #222; }}
  h1 {{ border-bottom: 1px solid #ddd; padding-bottom: 8px; }}
  ul {{ list-style: none; padding: 0; }}
  li {{ padding: 6px 0; border-bottom: 1px solid #f0f0f0; }}
  a {{ text-decoration: none; color: #0969da; }}
  a:hover {{ text-decoration: underline; }}
  .empty {{ color: #888; font-style: italic; }}
</style>
</head>
<body>
<h1>Markdown Browser</h1>
<p><code>{dir}</code></p>
<ul>{items}</ul>
</body>
</html>
"""

FILE_TMPL = """\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{title}</title>
<style>
  body {{ font-family: sans-serif; max-width: 860px; margin: 40px auto; padding: 0 20px; color: #222; }}
  a {{ color: #0969da; }}
  #content h1,h2,h3 {{ border-bottom: 1px solid #eee; padding-bottom: 4px; }}
  #content pre {{ background: #f6f8fa; padding: 12px; border-radius: 6px; overflow-x: auto; }}
  #content code {{ background: #f6f8fa; padding: 2px 4px; border-radius: 3px; font-size: 0.9em; }}
  #content pre code {{ background: none; padding: 0; }}
  #content blockquote {{ border-left: 4px solid #ddd; margin: 0; padding-left: 16px; color: #666; }}
  #content table {{ border-collapse: collapse; width: 100%; }}
  #content th, #content td {{ border: 1px solid #ddd; padding: 6px 12px; }}
  #content th {{ background: #f6f8fa; }}
  nav {{ margin-bottom: 24px; font-size: 0.9em; }}
</style>
</head>
<body>
<nav><a href="/">&#8592; Index</a></nav>
<div id="content"></div>
<script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
<script>
const raw = {raw};
document.getElementById('content').innerHTML = marked.parse(raw);
</script>
</body>
</html>
"""

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"  {self.address_string()} {fmt % args}")

    def send_html(self, body, code=200):
        encoded = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        path = urllib.parse.unquote(self.path.split("?")[0])
        abs_path = os.path.normpath(os.path.join(SERVE_DIR, path.lstrip("/")))

        # Prevent directory traversal
        if not abs_path.startswith(os.path.abspath(SERVE_DIR)):
            self.send_html("<h1>403 Forbidden</h1>", 403)
            return

        if path == "/" or os.path.isdir(abs_path):
            files = sorted(
                f for f in os.listdir(SERVE_DIR)
                if f.lower().endswith(".md")
            )
            if files:
                items = "".join(
                    f'<li><a href="/{html.escape(f)}">{html.escape(f)}</a></li>'
                    for f in files
                )
            else:
                items = '<li class="empty">No .md files found.</li>'
            self.send_html(INDEX_TMPL.format(dir=html.escape(SERVE_DIR), items=items))

        elif abs_path.lower().endswith(".md") and os.path.isfile(abs_path):
            with open(abs_path, encoding="utf-8") as f:
                content = f.read()
            import json
            self.send_html(FILE_TMPL.format(
                title=html.escape(os.path.basename(abs_path)),
                raw=json.dumps(content),
            ))

        else:
            self.send_html("<h1>404 Not Found</h1>", 404)

with http.server.HTTPServer(("", PORT), Handler) as srv:
    srv.serve_forever()
PYEOF
