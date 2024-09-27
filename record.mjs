//@ts-check
import { createServer } from 'http';
import { request } from 'https';
import { createHash } from 'crypto';
import { join } from 'path';
import { writeFileSync } from 'fs';

const PORT = 3000;

const flatpakManifest = {}

const server = createServer((req, res) => {
    if (!req.url) {
        res.writeHead(400)
        return res.end('URL missing')
    }
    // console.log(`Request start URL: ${req.method} ${req.url}`);

    const proxyRequest = request({
        hostname: 'registry.npmjs.org',
        port: 443,
        path: req.url,
        method: req.method,
    }, (proxyResponse) => {
        const { 'content-encoding': contentEncoding, 'content-length': contentLength, ...filteredHeaders } = proxyResponse.headers;
        const isJson = proxyResponse.headers['content-type'] && proxyResponse.headers['content-type'].includes('application/json');
        res.writeHead(proxyResponse.statusCode || 500, isJson ? filteredHeaders : proxyResponse.headers);
        // Check if the response is JSON
        // console.log({ isJson });
        const hash = createHash('sha512');
        if (isJson) {
            let data = '';
            proxyResponse.on('data', (chunk) => {
                data += chunk;
                hash.update(chunk)
            });
            proxyResponse.on('end', () => {
                console.log("end", data.length)
                data = data.replace(/https:\/\/registry\.npmjs\.org/g, 'http://localhost:3000');
                res.end(data);
            });
        } else {
            proxyResponse.on('data', (chunk) => {
                hash.update(chunk)
            });
            proxyResponse.pipe(res, { end: true });
        }
        proxyResponse.on('end', () => {
            const sha512 = hash.digest('hex')
            // console.log(`Request end URL: ${req.method} ${req.url}`, { isJson }, sha512);
            if (!req.url) {
                throw new Error("no req url");
            }
            flatpakManifest[req.url] = {
                type: 'file',
                url: `https://registry.npmjs.org${req.url}`,
                sha512,
                //TODO: decode uri?
                "dest-filename": join('npm-registry-proxy-offline-cache', req.url.endsWith(".tgz")? req.url:join(req.url, 'index.json')),
            }
        })
    });

    // Handle errors
    proxyRequest.on('error', (err) => {
        console.error(`Error: ${err.message}`);
        res.writeHead(500);
        res.end('Internal Server Error');
    });

    // Pipe the request data from the client to the target server
    req.pipe(proxyRequest, { end: true });
});

// Start the server
server.listen(PORT, () => {
    console.log(`Proxy server is running on http://localhost:${PORT}`);
});

function save() {
    const arrayManifest = Object.keys(flatpakManifest).map(url => flatpakManifest[url])
    writeFileSync('generated/proxy-registry-cache-manifest.json', JSON.stringify(arrayManifest, null, 2), 'utf-8')
}

process.on('SIGINT', () => {
    save()
    process.exit(0)
})

// IDEA: based on url convention or package name we could fuess "only-arches"