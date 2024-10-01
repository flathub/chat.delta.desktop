//@ts-check
import { createServer } from 'http';
import { request } from 'https';
import { createHash } from 'crypto';
import { basename, dirname, join } from 'path';
import { writeFileSync } from 'fs';

const PORT = 3000;

const flatpakManifest = {}

/** @type {string[]} */
const packages_which_should_dl_metdata = []

function stripSuffix(str, suffix) {
    if (str.endsWith(suffix)) {
        return str.slice(0, -suffix.length);
    }
    return str; // Return the original string if it doesn't end with the suffix
}

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
                // console.log("end", data.length)
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

            if (req.url.endsWith(".tgz")) {
                packages_which_should_dl_metdata.push(
                    stripSuffix(stripSuffix(req.url, basename(req.url)), '/-/')
                )
            }

            const destPath = join('npm-registry-proxy-offline-cache', req.url.endsWith(".tgz") ? req.url : join(req.url, 'index.json'))
            flatpakManifest[req.url] = {
                type: 'file',
                url: `https://registry.npmjs.org${req.url}`,
                sha512,
                //TODO: decode uri?
                dest: dirname(destPath),
                "dest-filename": basename(destPath),
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

async function save() {
    // force downloading of index files
    const indexUrls = packages_which_should_dl_metdata.map(relativeUrl => `http://localhost:${PORT}${relativeUrl}`)
    // console.log(indexUrls);

    await Promise.all(indexUrls.map(url => fetch(url)))

    const arrayManifest = Object.keys(flatpakManifest).map(url => flatpakManifest[url])
    arrayManifest.sort((a, b) => a.url.localeCompare(b.url))
    writeFileSync('generated/proxy-registry-cache-manifest.json', JSON.stringify(arrayManifest, null, 2), 'utf-8')
}

process.on('SIGINT', async (ev) => {
    await save()
    process.exit(0)
})

// IDEA: based on url convention or package name we could fuess "only-arches"