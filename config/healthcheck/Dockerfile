FROM node:20-alpine
WORKDIR /app
COPY package.json .
RUN npm install --omit=dev
COPY healthcheck.js .
EXPOSE 8008
CMD ["node", "healthcheck.js"]
