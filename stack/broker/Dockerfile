FROM node:20-alpine

WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev

COPY server.js ./
# providers/ is bind-mounted at runtime from ./broker/providers — not baked in

USER node
EXPOSE 8080
CMD ["node", "server.js"]
