import gleam/int
import gleam/list
import gleam/base
import gleam/result
import gleam/string
import gleam/crypto
import gleam/bit_string
import gleam/bitwise.{exclusive_or as bxor}
import mungo/error
import bison/bson
import bison/generic

pub fn first_payload(username: String) {
  let nonce =
    crypto.strong_random_bytes(24)
    |> base.encode64(True)

  ["n=", clean_username(username), ",r=", nonce]
  |> string.concat
}

pub fn first_message(payload) {
  let payload =
    ["n,,", payload]
    |> string.concat
    |> generic.from_string

  [
    #("saslStart", bson.Boolean(True)),
    #("mechanism", bson.Str("SCRAM-SHA-256")),
    #("payload", bson.Binary(bson.Generic(payload))),
    #("autoAuthorize", bson.Boolean(True)),
    #("options", bson.Document([#("skipEmptyExchange", bson.Boolean(True))])),
  ]
}

pub fn parse_first_reply(reply: List(#(String, bson.Value))) {
  case reply {
    [#("ok", bson.Double(0.0)), ..] ->
      Error(error.ServerError(error.AuthenticationFailed("")))

    [
      #("conversationId", bson.Int32(cid)),
      #("done", bson.Boolean(False)),
      #("payload", bson.Binary(bson.Generic(data))),
      #("ok", bson.Double(1.0)),
      ..
    ] -> {
      use data <- result.then(
        generic.to_string(data)
        |> result.map_error(fn(_) {
          error.ServerError(error.AuthenticationFailed(""))
        }),
      )
      use [#("r", rnonce), #("s", salt), #("i", i)] <- result.then(parse_payload(
        data,
      ))
      case int.parse(i) {
        Ok(iterations) ->
          case iterations >= 4096 {
            True -> Ok(#(#(rnonce, salt, iterations), data, cid))
            False -> Error(error.ServerError(error.AuthenticationFailed("")))
          }
        Error(Nil) -> Error(error.ServerError(error.AuthenticationFailed("")))
      }
    }
  }
}

pub fn second_message(
  server_params,
  first_payload,
  server_payload,
  cid,
  password,
) {
  let #(rnonce, salt, iterations) = server_params

  use salt <- result.then(
    base.decode64(salt)
    |> result.map_error(fn(_) {
      error.ServerError(error.AuthenticationFailed(""))
    }),
  )

  let salted_password = hi(password, salt, iterations)

  let client_key =
    crypto.hmac(
      bit_string.from_string("Client Key"),
      crypto.Sha256,
      salted_password,
    )

  let server_key =
    crypto.hmac(
      bit_string.from_string("Server Key"),
      crypto.Sha256,
      salted_password,
    )

  let stored_key = crypto.hash(crypto.Sha256, client_key)

  let auth_message =
    [first_payload, ",", server_payload, ",c=biws,r=", rnonce]
    |> string.concat
    |> generic.from_string

  let client_signature =
    crypto.hmac(generic.to_bit_string(auth_message), crypto.Sha256, stored_key)

  let second_payload =
    [
      "c=biws,r=",
      rnonce,
      ",p=",
      xor(client_key, client_signature, <<>>)
      |> base.encode64(True),
    ]
    |> string.concat
    |> generic.from_string

  let server_signature =
    crypto.hmac(generic.to_bit_string(auth_message), crypto.Sha256, server_key)

  #(
    [
      #("saslContinue", bson.Boolean(True)),
      #("conversationId", bson.Int32(cid)),
      #("payload", bson.Binary(bson.Generic(second_payload))),
    ],
    server_signature,
  )
  |> Ok
}

pub fn parse_second_reply(
  reply: List(#(String, bson.Value)),
  server_signature: BitString,
) {
  case reply {
    [#("ok", bson.Double(0.0)), ..] ->
      Error(error.ServerError(error.AuthenticationFailed("")))

    [
      #("conversationId", _),
      #("done", bson.Boolean(True)),
      #("payload", bson.Binary(bson.Generic(data))),
      #("ok", bson.Double(1.0)),
      ..
    ] -> {
      use data <- result.then(
        generic.to_string(data)
        |> result.map_error(fn(_) {
          error.ServerError(error.AuthenticationFailed(""))
        }),
      )

      use [#("v", data)] <- result.then(parse_payload(data))

      use received_signature <- result.then(
        base.decode64(data)
        |> result.map_error(fn(_) {
          error.ServerError(error.AuthenticationFailed(""))
        }),
      )

      case
        bit_string.byte_size(server_signature) == bit_string.byte_size(
          received_signature,
        ) && crypto.secure_compare(server_signature, received_signature)
      {
        True -> Ok(Nil)
        False -> Error(error.ServerError(error.AuthenticationFailed("")))
      }
    }
  }
}

fn parse_payload(payload: String) {
  payload
  |> string.split(",")
  |> list.try_map(fn(item) { string.split_once(item, "=") })
  |> result.map_error(fn(_) {
    error.ServerError(error.AuthenticationFailed(""))
  })
}

fn clean_username(username: String) {
  username
  |> string.replace("=", "=3D")
  |> string.replace(",", "=2C")
}

pub fn hi(password, salt, iterations) {
  // TODO: should cache with unique key constructed from params
  pbkdf2(crypto.Sha256, password, salt, iterations, 32)
}

@external(erlang, "crypto", "pbkdf2_hmac")
fn pbkdf2(
  alg: crypto.HashAlgorithm,
  password: String,
  salt: BitString,
  iterations: Int,
  key_len: Int,
) -> BitString

fn xor(a: BitString, b: BitString, storage: BitString) -> BitString {
  let <<fa, ra:bit_string>> = a
  let <<fb, rb:bit_string>> = b

  let new_storage =
    [storage, <<bxor(fa, fb)>>]
    |> bit_string.concat

  case [ra, rb] {
    [<<>>, <<>>] -> new_storage
    _ -> xor(ra, rb, new_storage)
  }
}
