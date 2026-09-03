# Builds the backend from https://github.com/xalonious/streaming-app (MIT).
# Pinned to a commit so builds are reproducible; bump manually when upgrading.
ARG STREAMING_APP_REF=9921b434a82a042c51b1be46e5efdbceb95e0bda

FROM node:22-alpine AS build
ARG STREAMING_APP_REF
RUN apk add --no-cache git
WORKDIR /src
RUN git clone https://github.com/xalonious/streaming-app.git . \
    && git checkout "$STREAMING_APP_REF"
WORKDIR /src/backend
RUN npm ci
RUN npm run build

FROM node:22-alpine
ENV NODE_ENV=production
WORKDIR /app
COPY --from=build /src/backend/package.json /src/backend/package-lock.json ./
RUN npm ci --omit=dev
COPY --from=build /src/backend/dist ./dist
EXPOSE 3000
CMD ["node", "dist/index.js"]
