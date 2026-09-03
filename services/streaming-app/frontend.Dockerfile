# Builds the frontend from https://github.com/xalonious/streaming-app (MIT).
# Pinned to a commit so builds are reproducible; bump manually when upgrading.
ARG STREAMING_APP_REF=9921b434a82a042c51b1be46e5efdbceb95e0bda

FROM node:22-alpine AS build
ARG STREAMING_APP_REF
RUN apk add --no-cache git
WORKDIR /src
RUN git clone https://github.com/xalonious/streaming-app.git . \
    && git checkout "$STREAMING_APP_REF"
WORKDIR /src/frontend
RUN npm ci
RUN npm run build

FROM nginx:alpine
COPY --from=build /src/frontend/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
