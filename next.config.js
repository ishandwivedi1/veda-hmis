/** @type {import('next').NextConfig} */
const nextConfig = {
  // Puppeteer + @sparticuz/chromium ship native binaries and brotli-packed
  // library files (e.g. libnss3.so) that Next.js's webpack bundling strips
  // out if left to process them normally. Marking them "external" tells
  // Next.js to leave them as plain node_modules requires instead, which is
  // required for headless Chrome to actually launch in the deployed
  // serverless function (used for invoice PDF generation).
  serverExternalPackages: ['@sparticuz/chromium-min', 'puppeteer-core'],
  experimental: {
    serverActions: {
      // GitHub Codespaces forwards your port through a proxy URL like
      // https://<name>-3000.app.github.dev -- Next.js's Server Actions
      // check the request's origin against the server's host, and this
      // wildcard tells it to trust Codespaces' forwarding domains.
      allowedOrigins: ['*.app.github.dev', '*.github.dev', 'localhost:3000'],
    },
  },
};

module.exports = nextConfig;

