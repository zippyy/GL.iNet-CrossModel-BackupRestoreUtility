FROM node:22-alpine

WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY . .
RUN mkdir -p /app/data/backups && chown -R node:node /app
USER node
EXPOSE 8787
ENV NODE_ENV=production
CMD ["npm", "start"]
