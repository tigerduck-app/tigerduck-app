# Vendored copy

`darkreader.js` is [Dark Reader](https://github.com/darkreader/darkreader) 4.9.133, the
browser build from the npm package `darkreader`, unmodified. License: MIT (see `LICENSE`,
unmodified, from the same package).

- Source: `https://registry.npmjs.org/darkreader/-/darkreader-4.9.133.tgz`, checked against the
  registry's `dist.integrity`,
  `sha512-d3dRGpVgoBnMXl9qfnTuRvrdtO/9e6puFbsDwxfycTwbRNFI+sNX+093h6qnNo4VosyHHUaIXyunDWvbEudTRQ==`.
- `darkreader.js` SHA-256: `82619e7a0bcabbea15a91488bc74fd0f9ba8f8f2a1cc67527f78166037cce166`.

`BrowserPageScripts.darken` runs it in the browser's own script world. To update, replace both
files from the new tarball after checking its integrity, change the version here and in
`BUNDLED` in `tools/generate_licenses.py`, and run `python3 tools/generate_licenses.py`.
