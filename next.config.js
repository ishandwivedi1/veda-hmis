/** @type {import('next').NextConfig} */
const nextConfig = {
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

