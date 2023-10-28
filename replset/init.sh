openssl rand -base64 512 > spawnfest.key

podman build -t replset-node .

podman network create replset-network
podman run -d -p 1024:27017 --name dante  --net replset-network -e MONGO_INITDB_ROOT_USERNAME=spawn -e MONGO_INITDB_ROOT_PASSWORD=fest replset-node
podman run -d -p 2048:27017 --name vergil --net replset-network -e MONGO_INITDB_ROOT_USERNAME=spawn -e MONGO_INITDB_ROOT_PASSWORD=fest replset-node
podman run -d -p 4096:27017 --name lady   --net replset-network -e MONGO_INITDB_ROOT_USERNAME=spawn -e MONGO_INITDB_ROOT_PASSWORD=fest replset-node