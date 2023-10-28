-module(mungo_ffi).

-export([tcp_send/2]).

tcp_send(Socket, Data) ->
    case gen_tcp:send(Socket, Data) of
        ok -> {ok, nil};
        {error, Reason} -> {error, Reason}
    end.
