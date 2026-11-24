FROM node:22-slim
WORKDIR /app

# Prisma needs OpenSSL
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends openssl ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# install everything (the prisma CLI is a dev dependency and is needed for migrate deploy)
COPY package*.json ./
RUN npm ci

# prisma/ also brings prisma/seed-data/ when it exists on the build machine (it is git-ignored): the
# exported accounts, shops, products and media that seed-import.js loads on the first start.
COPY prisma ./prisma
RUN npx prisma generate

COPY src ./src
COPY scripts ./scripts

# The uploads volume takes this folder's owner on first use, so the API (user node) can write to it.
RUN mkdir -p /app/uploads/media /app/uploads/private /app/uploads/staging && chown -R node:node /app/uploads

ENV NODE_ENV=production
USER node
EXPOSE 4000
CMD ["node", "src/server.js"]