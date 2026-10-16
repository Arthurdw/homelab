FROM alpine:3.21

# Smart-HTTP Git server: nginx + fcgiwrap + git-http-backend.
# Read-only, anonymous — for the disposable lab only.
RUN apk add --no-cache git git-daemon nginx fcgiwrap spawn-fcgi

COPY nginx.conf /etc/nginx/nginx.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# The bare mirror of this repository is baked in at build time (see lab-up.sh).
COPY homelab.git /git/homelab.git

EXPOSE 80
CMD ["/entrypoint.sh"]
