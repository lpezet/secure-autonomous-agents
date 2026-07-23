FROM nginx:alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
# Extension point: bind-mount host snippets here (see nginx.conf). Created
# empty so the image is valid unmounted — nginx tolerates an empty glob.
RUN mkdir -p /etc/nginx/gateway.d
