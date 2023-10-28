import gleam/int
import gleam/uri
import gleam/bool
import gleam/list
import gleam/string
import gleam/result
import gleam/option
import gleam/bit_string
import mungo/tcp
import mungo/scram
import mungo/error
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

pub fn connect(uri: String) -> Result(Database, error.MongoError) {
  use info <- result.then(parse_connection_string(uri))

  case info {
    #(auth, hosts, db) -> {
      use connections <- result.then(list.try_map(
        hosts,
        fn(host) {
          use socket <- result.then(
            tcp.connect(host.0, host.1)
            |> result.map_error(fn(error) { error.TCPError(error) }),
          )

          Ok(Connection(socket, is_primary(socket, db)))
        },
      ))

      let assert Ok(Connection(primary_socket, _)) =
        list.find(connections, fn(connection) { connection.primary })

      case auth {
        option.None -> Ok(Database(db, connections))
        option.Some(#(username, password, auth_source)) -> {
          use _ <- result.then(authenticate(
            primary_socket,
            username,
            password,
            auth_source,
          ))

          Ok(Database(db, connections))
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

pub fn execute(
  collection: Collection,
  cmd: List(#(String, bson.Value)),
) -> Result(List(#(String, bson.Value)), error.MongoError) {
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
        ]) -> {
          let assert Ok(error) = list.key_find(error.code_to_server_error, code)
          let error = error(msg)

          case error.is_retriable_error(error) {
            True ->
              case error.is_not_primary_error(error) {
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
                    ]) -> {
                      let assert Ok(error) =
                        list.key_find(error.code_to_server_error, code)
                      Error(error.ServerError(error(msg)))
                    }

                    Ok(result) -> Ok(result)
                    Error(error) -> Error(error)
                  }
                }

                False ->
                  case send_cmd(socket, name, cmd) {
                    Ok([
                      #("ok", bson.Double(0.0)),
                      #("errmsg", bson.Str(msg)),
                      #("code", bson.Int32(code)),
                      #("codeName", _),
                    ]) -> {
                      let assert Ok(error) =
                        list.key_find(error.code_to_server_error, code)
                      Error(error.ServerError(error(msg)))
                    }

                    Ok(result) -> Ok(result)
                    Error(error) -> Error(error)
                  }
              }
            False -> Error(error.ServerError(error))
          }
        }

        Ok(result) -> Ok(result)
        Error(error) -> Error(error)
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
    Error(_) -> False
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
    [#("ok", bson.Double(0.0)), ..] ->
      Error(error.ServerError(error.AuthenticationFailed("")))
    reply -> scram.parse_second_reply(reply, server_signature)
  }
}

fn send_cmd(
  socket: tcp.Socket,
  db: String,
  cmd: List(#(String, bson.Value)),
) -> Result(List(#(String, bson.Value)), error.MongoError) {
  let cmd = list.key_set(cmd, "$db", bson.Str(db))
  let encoded = encode(cmd)
  let size = bit_string.byte_size(encoded) + 21

  let packet =
    [<<size:32-little, 0:32, 0:32, 2013:32-little, 0:32, 0>>, encoded]
    |> bit_string.concat

  case tcp.send(socket, packet) {
    Ok(_) ->
      case tcp.receive(socket) {
        Ok(response) -> {
          let <<_:168, rest:bit_string>> = response
          case decode(rest) {
            Ok(result) -> Ok(result)
            Error(Nil) -> Error(error.BSONError)
          }
        }
        Error(tcp_error) -> Error(error.TCPError(tcp_error))
      }
    Error(tcp_error) -> Error(error.TCPError(tcp_error))
  }
}

pub fn parse_connection_string(uri: String) {
  use <- bool.guard(
    !string.starts_with(uri, "mongodb://"),
    Error(error.ConnectionStringError),
  )
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
            _ -> Error(error.ConnectionStringError)
          }
        _ -> Error(error.ConnectionStringError)
      }
    Error(Nil) -> Ok(#(option.None, uri))
  })

  use #(hosts, db_and_options) <- result.then(
    string.split_once(rest, "/")
    |> result.map_error(fn(_) { error.ConnectionStringError }),
  )
  use hosts <- result.then(
    hosts
    |> string.split(",")
    |> list.map(fn(host) {
      case string.starts_with(host, ":") {
        True -> Error(error.ConnectionStringError)
        False -> Ok(host)
      }
    })
    |> list.try_map(fn(host) {
      case host {
        Ok(host) -> {
          case string.split_once(host, ":") {
            Ok(#(host, port)) -> {
              use port <- result.then(
                int.parse(port)
                |> result.map_error(fn(_) { error.ConnectionStringError }),
              )
              Ok(#(host, port))
            }
            Error(Nil) -> Ok(#(host, 27_017))
          }
        }
        Error(error) -> Error(error)
      }
    }),
  )

  case string.split(db_and_options, "?") {
    [db] if db != "" -> {
      use db <- result.then(
        uri.percent_decode(db)
        |> result.map_error(fn(_) { error.ConnectionStringError }),
      )
      Ok(#(
        auth
        |> option.map(fn(auth) { #(auth.0, auth.1, db) }),
        hosts,
        db,
      ))
    }

    [db, "authSource=" <> auth_source] if db != "" -> {
      use db <- result.then(
        uri.percent_decode(db)
        |> result.map_error(fn(_) { error.ConnectionStringError }),
      )
      Ok(#(
        auth
        |> option.map(fn(auth) { #(auth.0, auth.1, auth_source) }),
        hosts,
        db,
      ))
    }

    _ -> Error(error.ConnectionStringError)
  }
}
