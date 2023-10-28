FROM mongo:latest

COPY spawnfest.key /data/spawnfest.key
RUN chown mongodb:mongodb /data/spawnfest.key
RUN chmod 400 /data/spawnfest.key

CMD ["mongod", "--bind_ip_all", "--replSet", "spawnfest-replset", "--keyFile", "/data/spawnfest.key", "--auth"]
