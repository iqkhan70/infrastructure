# tiny static app — VERSION is baked in at docker build (CI passes git SHA / tag)
FROM busybox:1.36
ARG VERSION=dev
RUN mkdir -p /www && printf '%s\n' "catalog-${VERSION}" > /www/index.html
EXPOSE 8080
CMD ["httpd", "-f", "-v", "-p", "8080", "-h", "/www"]
