# Stage 1: install production deps only
FROM node:24.22.3-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# Stage 2: runtime, non-root (uid 1000 = "node" user in the official image; numeric so k8s runAsNonRoot can verify it)
FROM node:24.22.3-alpine
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY server.js package.json ./
USER 1000
EXPOSE 3000
# Run node directly (not "npm start"): one process, gets signals, less RAM.
CMD ["node", "server.js"]
