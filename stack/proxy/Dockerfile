FROM mitmproxy/mitmproxy:12.2.2

USER root
RUN pip install --no-cache-dir requests cachetools

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

CMD ["/entrypoint.sh"]
