// Minimal static file server for local development: node tools/serve.mjs [port]

import { createServer } from "node:http";
import { createReadStream, statSync } from "node:fs";
import { dirname, extname, join, normalize, sep } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const PORT = Number(process.argv[2] || process.env.PORT || 8080);

const TYPES = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".mjs": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".json": "application/json",
    ".wasm": "application/wasm",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".txt": "text/plain; charset=utf-8",
};

export function serve(port = PORT) {
    const server = createServer((req, res) => {
        const url = new URL(req.url, "http://localhost");
        let path = normalize(join(ROOT, decodeURIComponent(url.pathname)));
        if (path !== ROOT && !path.startsWith(ROOT + sep)) {
            res.writeHead(403).end("Forbidden");
            return;
        }
        let stat;
        try {
            stat = statSync(path);
            if (stat.isDirectory()) {
                path = join(path, "index.html");
                stat = statSync(path);
            }
        } catch {
            res.writeHead(404).end("Not found");
            return;
        }
        res.writeHead(200, {
            "Content-Type": TYPES[extname(path)] || "application/octet-stream",
            "Content-Length": stat.size,
            "Cache-Control": "no-cache",
        });
        createReadStream(path).pipe(res);
    });
    return new Promise((resolve) => server.listen(port, () => resolve(server)));
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
    await serve();
    console.log(`WebVM: http://localhost:${PORT}/`);
}
