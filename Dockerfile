FROM node:22-alpine
WORKDIR /app
COPY app/ .
ARG BUILD_SHA=dev
ENV BUILD_SHA=$BUILD_SHA
USER node
EXPOSE 8080
CMD ["node", "index.js"]
