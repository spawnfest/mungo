![mungo](https://raw.githubusercontent.com/massivefermion/mungo/main/logo.png)

[![Package Version](https://img.shields.io/hexpm/v/mungo)](https://hex.pm/packages/mungo)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/mungo/)

# mungo
> mungo: a felted fabric made from the shredded fibre of repurposed woollen cloth
---

A mongodb driver for gleam

## Installation

```sh
gleam add mungo
```

## SpawnFest 2023

As should already be clear, this is an already existing package. As far as SpawnFest 2023 is concerned, the goal is to be able to perform all of the already supported commands against a mongodb replica set as a first step for supporting more general mongodb cluster topologies.

I also think it's appropriate to explain my mongodb cluster setup to help other people replicate my results. I'll use a mongodb replica set created using [podman](https://podman.io) and the [latest official mongodb docker image](https://hub.docker.com/_/mongo).

The first step is to create a podman network:
```
podman network create replset-network
```

Then we need to create at least three nodes(port mappings are only for accessing the nodes from the host):
```
podman run -d -p 1024:27017 --name dante  --net replset-network mongo:latest --replSet spawnfest-replset
podman run -d -p 2048:27017 --name vergil --net replset-network mongo:latest --replSet spawnfest-replset
podman run -d -p 4096:27017 --name lady   --net replset-network mongo:latest --replSet spawnfest-replset
```

Finally you can use `mongosh` to connect to any of the nodes, initialize the replica set and add the other nodes:
```
mongosh --port 1024
```

```
> rs.initiate()
> rs.add('vergil')
> rs.add('lady')
```

## Usage

```gleam
import gleam/uri
import gleam/option
import mungo
import mungo/crud.{Sort, Upsert}
import mungo/aggregation.{
  Let, add_fields, aggregate, match, pipelined_lookup, to_cursor, unwind,
}
import bison/bson

pub fn main() {
  let encoded_password = uri.percent_encode("strong password")
  let assert Ok(db) =
    mungo.connect(
      "mongodb://app-dev:" <> encoded_password <> "@localhost/app-db?authSource=admin",
    )

  let users =
    db
    |> mungo.collection("users")

  let _ =
    users
    |> mungo.insert_many([
      [
        #("username", bson.Str("jmorrow")),
        #("name", bson.Str("vincent freeman")),
        #("email", bson.Str("jmorrow@gattaca.eu")),
        #("age", bson.Int32(32)),
      ],
      [
        #("username", bson.Str("real-jerome")),
        #("name", bson.Str("jerome eugene morrow")),
        #("email", bson.Str("real-jerome@running.at")),
        #("age", bson.Int32(32)),
      ],
    ])

  let _ =
    users
    |> mungo.update_one(
      [#("username", bson.Str("real-jerome"))],
      [
        #(
          "$set",
          bson.Document([
            #("username", bson.Str("eugene")),
            #("email", bson.Str("eugene@running.at ")),
          ]),
        ),
      ],
      [Upsert],
    )

  let assert Ok(yahoo_cursor) =
    users
    |> mungo.find_many(
      [#("email", bson.Regex(#("yahoo", "")))],
      [Sort([#("username", bson.Int32(-1))])],
    )
  let _yahoo_users = mungo.to_list(yahoo_cursor)

  let assert Ok(underage_lindsey_cursor) =
    users
    |> aggregate([Let([#("minimum_age", bson.Int32(21))])])
    |> match([
      #(
        "$expr",
        bson.Document([
          #("$lt", bson.Array([bson.Str("$age"), bson.Str("$$minimum_age")])),
        ]),
      ),
    ])
    |> add_fields([
      #(
        "first_name",
        bson.Document([
          #(
            "$arrayElemAt",
            bson.Array([
              bson.Document([
                #("$split", bson.Array([bson.Str("$name"), bson.Str(" ")])),
              ]),
              bson.Int32(0),
            ]),
          ),
        ]),
      ),
    ])
    |> match([#("first_name", bson.Str("lindsey"))])
    |> pipelined_lookup(
      from: "profiles",
      define: [#("user", bson.Str("$username"))],
      pipeline: [
        [
          #(
            "$match",
            bson.Document([
              #(
                "$expr",
                bson.Document([
                  #(
                    "$eq",
                    bson.Array([bson.Str("$username"), bson.Str("$$user")]),
                  ),
                ]),
              ),
            ]),
          ),
        ],
      ],
      alias: "profile",
    )
    |> unwind("$profile", False)
    |> to_cursor

  let assert #(option.Some(_underage_lindsey), underage_lindsey_cursor) =
    underage_lindsey_cursor
    |> mungo.next

  let assert #(option.None, _) =
    underage_lindsey_cursor
    |> mungo.next
}
```
