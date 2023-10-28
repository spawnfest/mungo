import gleam/list
import gleam/string
import gleam/bit_string

pub type Socket

pub type TCPError {
  // https://www.erlang.org/doc/man/inet#type-posix
  Closed
  Timeout
  Eaddrinuse
  Eaddrnotavail
  Eafnosupport
  Ealready
  Econnaborted
  Econnrefused
  Econnreset
  Edestaddrreq
  Ehostdown
  Ehostunreach
  Einprogress
  Eisconn
  Emsgsize
  Enetdown
  Enetunreach
  Enopkg
  Enoprotoopt
  Enotconn
  Enotty
  Enotsock
  Eproto
  Eprotonosupport
  Eprototype
  Esocktnosupport
  Etimedout
  Ewouldblock
  Exbadport
  Exbadseq
  // https://www.erlang.org/doc/man/file#type-posix
  Eacces
  Eagain
  Ebadf
  Ebadmsg
  Ebusy
  Edeadlk
  Edeadlock
  Edquot
  Eexist
  Efault
  Efbig
  Eftype
  Eintr
  Einval
  Eio
  Eisdir
  Eloop
  Emfile
  Emlink
  Emultihop
  Enametoolong
  Enfile
  Enobufs
  Enodev
  Enolck
  Enolink
  Enoent
  Enomem
  Enospc
  Enosr
  Enostr
  Enosys
  Enotblk
  Enotdir
  Enotsup
  Enxio
  Eopnotsupp
  Eoverflow
  Eperm
  Epipe
  Erange
  Erofs
  Espipe
  Esrch
  Estale
  Etxtbsy
  Exdev
}

type TCPOption {
  Binary
  Active(Bool)
}

pub fn connect(host: String, port: Int) {
  tcp_connect(
    host
    |> string.to_graphemes
    |> list.map(fn(char) {
      let <<code>> = bit_string.from_string(char)
      code
    }),
    port,
    [Binary, Active(False)],
  )
}

pub fn send(socket, data) {
  tcp_send(socket, data)
}

pub fn receive(socket) {
  case tcp_receive(socket, 4) {
    Ok(<<size:32-little>>) ->
      case tcp_receive(socket, size - 4) {
        Ok(rest) ->
          bit_string.append(<<size:32-little>>, rest)
          |> Ok
        Error(error) -> Error(error)
      }
    Error(error) -> Error(error)
  }
}

@external(erlang, "gen_tcp", "connect")
fn tcp_connect(
  host: List(Int),
  port: Int,
  ops: List(TCPOption),
) -> Result(Socket, TCPError)

@external(erlang, "mungo_ffi", "tcp_send")
fn tcp_send(socket: Socket, data: BitString) -> Result(Nil, TCPError)

@external(erlang, "gen_tcp", "recv")
fn tcp_receive(socket: Socket, length: Int) -> Result(BitString, TCPError)
