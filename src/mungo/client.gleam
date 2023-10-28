import gleam/int
import gleam/uri
import gleam/bool
import gleam/list
import gleam/string
import gleam/option
import gleam/result
import gleam/bit_string
import mungo/tcp
import mungo/scram
import bison/bson
import bison.{decode, encode}

pub opaque type Connection {
  Connection(socket: tcp.Socket, primary: Bool)
}

pub opaque type Database {
  Database(name: String, connections: List(Connection))
}

pub type Collection {
  Collection(db: Database, name: String)
}

pub fn connect(uri: String) -> Result(Database, Nil) {
  use info <- result.then(parse_connection_string(uri))
  case info {
    #(auth, [#(host, port)], db, auth_source) -> {
      use socket <- result.then(tcp.connect(host, port))
      case auth {
        option.None -> Ok(Database(db, [Connection(socket, True)]))
        option.Some(#(username, password)) -> {
          use _ <- result.then(case auth_source {
            option.None -> authenticate(socket, username, password, db)
            option.Some(source) ->
              authenticate(socket, username, password, source)
          })
          Ok(Database(db, [Connection(socket, True)]))
        }
      }
    }
  }
}

pub fn collection(db: Database, name: String) -> Collection {
  Collection(db, name)
}

pub fn get_more(collection: Collection, id: Int, batch_size: Int) {
  execute(
    collection,
    [
      #("getMore", bson.Int64(id)),
      #("collection", bson.Str(collection.name)),
      #("batchSize", bson.Int32(batch_size)),
    ],
  )
}

const find_new_primary_errors = [189, 10_107, 13_435, 13_436, 10_058]

pub fn execute(
  collection: Collection,
  cmd: List(#(String, bson.Value)),
) -> Result(List(#(String, bson.Value)), #(Int, String)) {
  case collection.db {
    Database(name, connections) -> {
      let assert Ok(Connection(socket, True)) =
        list.find(connections, fn(connection) { connection.primary })

      case send_cmd(socket, name, cmd) {
        Ok([
          #("ok", bson.Double(0.0)),
          #("errmsg", bson.Str(msg)),
          #("code", bson.Int32(code)),
          #("codeName", _),
        ]) ->
          case list.contains(find_new_primary_errors, code) {
            True -> {
              let assert Ok(Connection(socket, True)) =
                list.find(
                  connections,
                  fn(connection) {
                    is_primary(connection.socket, collection.db.name)
                  },
                )

              case send_cmd(socket, name, cmd) {
                Ok([
                  #("ok", bson.Double(0.0)),
                  #("errmsg", bson.Str(msg)),
                  #("code", bson.Int32(code)),
                  #("codeName", _),
                ]) -> Error(#(code, msg))
                Ok(result) -> Ok(result)
                Error(Nil) -> Error(#(-2, ""))
              }
            }

            False -> Error(#(code, msg))
          }

        Ok(result) -> Ok(result)
        Error(Nil) -> Error(#(-2, ""))
      }
    }
  }
}

fn is_primary(socket: tcp.Socket, db: String) {
  case send_cmd(socket, db, [#("hello", bson.Int32(1))]) {
    Ok(reply) ->
      case list.key_find(reply, "isWritablePrimary") {
        Ok(bson.Boolean(True)) -> True
        _ -> False
      }
    Error(Nil) -> False
  }
}

fn authenticate(
  socket: tcp.Socket,
  username: String,
  password: String,
  auth_source: String,
) {
  let first_payload = scram.first_payload(username)

  let first = scram.first_message(first_payload)

  use reply <- result.then(send_cmd(socket, auth_source, first))

  use #(server_params, server_payload, cid) <- result.then(scram.parse_first_reply(
    reply,
  ))

  use #(second, server_signature) <- result.then(scram.second_message(
    server_params,
    first_payload,
    server_payload,
    cid,
    password,
  ))

  use reply <- result.then(send_cmd(socket, auth_source, second))

  case reply {
    [#("ok", bson.Double(0.0)), ..] -> Error(Nil)
    reply -> scram.parse_second_reply(reply, server_signature)
  }
}

fn send_cmd(
  socket: tcp.Socket,
  db: String,
  cmd: List(#(String, bson.Value)),
) -> Result(List(#(String, bson.Value)), Nil) {
  let cmd = list.key_set(cmd, "$db", bson.Str(db))
  let encoded = encode(cmd)
  let size = bit_string.byte_size(encoded) + 21

  let packet =
    [<<size:32-little, 0:32, 0:32, 2013:32-little, 0:32, 0>>, encoded]
    |> bit_string.concat
  case tcp.send(socket, packet) {
    tcp.OK ->
      case tcp.receive(socket) {
        Ok(response) -> {
          let <<_:168, rest:bit_string>> = response
          case decode(rest) {
            Ok(result) -> Ok(result)
            Error(Nil) -> Error(Nil)
          }
        }
        Error(Nil) -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

pub fn parse_connection_string(uri: String) {
  use <- bool.guard(!string.starts_with(uri, "mongodb://"), Error(Nil))
  let uri = string.drop_left(uri, 10)

  use #(auth, rest) <- result.then(case string.split_once(uri, "@") {
    Ok(#(auth, rest)) ->
      case string.split_once(auth, ":") {
        Ok(#(username, password)) if username != "" && password != "" ->
          case
            [username, password]
            |> list.map(uri.percent_decode)
          {
            [Ok(username), Ok(password)] ->
              Ok(#(option.Some(#(username, password)), rest))
            _ -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    Error(Nil) -> Ok(#(option.None, uri))
  })

  use #(hosts, db_and_options) <- result.then(string.split_once(rest, "/"))
  use hosts <- result.then(
    hosts
    |> string.split(",")
    |> list.map(fn(host) {
      case string.starts_with(host, ":") {
        True -> Error(Nil)
        False -> Ok(host)
      }
    })
    |> list.try_map(fn(host) {
      case host {
        Ok(host) -> {
          case string.split_once(host, ":") {
            Ok(#(host, port)) -> {
              use port <- result.then(int.parse(port))
              Ok(#(host, port))
            }
            Error(Nil) -> Ok(#(host, 27_017))
          }
        }
        Error(Nil) -> Error(Nil)
      }
    }),
  )

  case string.split(db_and_options, "?") {
    [db] if db != "" -> {
      use db <- result.then(uri.percent_decode(db))
      Ok(#(auth, hosts, db, option.None))
    }

    [db, "authSource=" <> auth_source] if db != "" -> {
      use db <- result.then(uri.percent_decode(db))
      Ok(#(auth, hosts, db, option.Some(auth_source)))
    }

    _ -> Error(Nil)
  }
}
