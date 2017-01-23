%%%===================================================================
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @doc Module abstracting Websockets over TCP connection to XMPP server
%%% @end
%%%===================================================================

-module(escalus_ws).
-behaviour(gen_server).
-behaviour(escalus_connection).

-include_lib("exml/include/exml_stream.hrl").
-include("escalus.hrl").

%% API exports
-export([connect/1,
         send/2,
         is_connected/1,
         upgrade_to_tls/1,
         use_zlib/1,
         reset_parser/1,
         set_filter_predicate/2,
         stop/1,
         kill/1,
         stream_start_req/1,
         stream_end_req/1,
         assert_stream_start/2,
         assert_stream_end/2]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(WAIT_FOR_SOCKET_CLOSE_TIMEOUT, 200).
-define(HANDSHAKE_TIMEOUT, 3000).
-define(SERVER, ?MODULE).

-record(state, {owner, socket, parser, legacy_ws, compress = false,
                event_client, filter_pred}).

%%%===================================================================
%%% API
%%%===================================================================

-spec connect([proplists:property()]) -> pid().
connect(Args) ->
    {ok, Pid} = gen_server:start_link(?MODULE, [Args, self()], []),
    Pid.

send(Pid, Elem) ->
    gen_server:cast(Pid, {send, Elem}).

is_connected(Pid) ->
    erlang:is_process_alive(Pid).

reset_parser(Pid) ->
    gen_server:cast(Pid, reset_parser).

stop(Pid) ->
    try
        gen_server:call(Pid, stop)
    catch
        exit:{noproc, {gen_server, call, _}} ->
            already_stopped;
        exit:{normal, {gen_server, call, _}} ->
            already_stopped
    end.

kill(Pid) ->
    %% Use `kill_connection` to avoid confusion with exit reason `kill`.
    catch gen_server:call(Pid, kill_connection).

-spec set_filter_predicate(escalus_connection:client(),
    escalus_connection:filter_pred()) -> ok.
set_filter_predicate(Pid, Pred) ->
    gen_server:call(Pid, {set_filter_pred, Pred}).

upgrade_to_tls(_) ->
    throw(starttls_not_supported).

%% TODO: this is en exact duplicate of escalus_tcp:use_zlib/2, DRY!
use_zlib(#client{rcv_pid = Pid} = Client) ->
    escalus_connection:send(Client, escalus_stanza:compress(<<"zlib">>)),
    Compressed = escalus_connection:get_stanza(Client, compressed),
    escalus:assert(is_compressed, Compressed),
    gen_server:call(Pid, use_zlib),
    escalus_session:start_stream(Client).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% TODO: refactor all opt defaults taken from Args into a default_opts function,
%%       so that we know what options the module actually expects
init([Args, Owner]) ->
    Host = get_host(Args, "localhost"),
    Port = get_port(Args, 5280),
    Resource = get_resource(Args, "/ws-xmpp"),
    LegacyWS = get_legacy_ws(Args, false),
    EventClient = proplists:get_value(event_client, Args),
    SSL = proplists:get_value(ssl, Args, false),
    WSOptions = [{ssl, SSL}],
    {ok, Socket} = wsecli:start(Host, Port, Resource, WSOptions),
    Pid = self(),
    wsecli:on_open(Socket, fun() -> Pid ! opened end),
    wsecli:on_error(Socket, fun(Reason) -> Pid ! {error, Reason} end),
    wsecli:on_message(Socket, fun(Type, Data) -> Pid ! {Type, Data} end),
    wsecli:on_close(Socket, fun(_) -> Pid ! tcp_closed end),
    wait_for_socket_start(),
    ParserOpts = if
                     LegacyWS -> [];
                     true -> [{infinite_stream, true}, {autoreset, true}]
                 end,
    {ok, Parser} = exml_stream:new_parser(ParserOpts),
    {ok, #state{owner = Owner,
                socket = Socket,
                parser = Parser,
                legacy_ws = LegacyWS,
                event_client = EventClient}}.

handle_call(use_zlib, _, #state{parser = Parser, socket = Socket} = State) ->
    Zin = zlib:open(),
    Zout = zlib:open(),
    ok = zlib:inflateInit(Zin),
    ok = zlib:deflateInit(Zout),
    {ok, NewParser} = exml_stream:reset_parser(Parser),
    {reply, Socket, State#state{parser = NewParser,
                                compress = {zlib, {Zin,Zout}}}};
handle_call({set_filter_pred, Pred}, _From, State) ->
    {reply, ok, State#state{filter_pred = Pred}};
handle_call(kill_connection, _, S) ->
    {stop, normal, ok, S};
handle_call(stop, _From, State) ->
    close_compression_streams(State#state.compress),
    wait_until_closed(),
    {stop, normal, ok, State}.

handle_cast({send, Elem}, State) ->
    Data = case State#state.compress of
               {zlib, {_, Zout}} -> zlib:deflate(Zout, exml:to_iolist(Elem), sync);
               false -> exml:to_iolist(Elem)
           end,
    wsecli:send(State#state.socket,Data),
    {noreply, State};
handle_cast(reset_parser, #state{parser = Parser} = State) ->
    {ok, NewParser} = exml_stream:reset_parser(Parser),
    {noreply, State#state{parser = NewParser}}.

handle_info(tcp_closed, State) ->
    {stop, normal, State};
handle_info({error, Reason}, State) ->
    {stop, Reason, State};
handle_info({text, Data}, State) ->
    handle_data(list_to_binary(lists:flatten(Data)), State);
handle_info({binary, Data}, State) ->
    handle_data(Data, State);
handle_info(_, State) ->
    {noreply, State}.

terminate(_Reason, #state{socket = Socket} = State) ->
    common_terminate(_Reason, State),
    wsecli:stop(Socket).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Helpers
%%%===================================================================

handle_data(Data, State = #state{parser = Parser,
                                 compress = Compress}) ->
    {ok, NewParser, Stanzas} =
        case Compress of
            false ->
                exml_stream:parse(Parser, Data);
            {zlib, {Zin,_}} ->
                Decompressed = iolist_to_binary(zlib:inflate(Zin, Data)),
                exml_stream:parse(Parser, Decompressed)
        end,
    NewState = State#state{parser = NewParser},
    escalus_connection:maybe_forward_to_owner(NewState#state.filter_pred,
                                              NewState,
                                              Stanzas,
                                              fun forward_to_owner/2),
    case lists:filter(fun is_stream_end/1, Stanzas) of
        [] -> {noreply, NewState};
        _ -> {stop, normal, NewState}
    end.

-spec is_stream_end(exml_stream:element()) -> boolean().
is_stream_end(#xmlstreamend{}) -> true;
is_stream_end(_) -> false.

forward_to_owner(Stanzas, #state{owner = Owner,
                                 event_client = EventClient}) ->
    lists:foreach(fun(Stanza) ->
                          escalus_event:incoming_stanza(EventClient, Stanza),
                          Owner ! {stanza, self(), Stanza}
                  end, Stanzas).

common_terminate(_Reason, #state{parser = Parser}) ->
    exml_stream:free_parser(Parser).

wait_until_closed() ->
    receive
        tcp_closed ->
            ok
    after ?WAIT_FOR_SOCKET_CLOSE_TIMEOUT ->
            ok
    end.

wait_for_socket_start() ->
    receive
        opened ->
            ok
    after ?HANDSHAKE_TIMEOUT ->
            throw(handshake_timeout)
    end.

-spec get_port(list(), inet:port_number()) -> inet:port_number().
get_port(Args, Default) ->
    get_option(port, Args, Default).

-spec get_host(list(), string()) -> string().
get_host(Args, Default) ->
    maybe_binary_to_list(get_option(host, Args, Default)).

-spec get_resource(list(), string()) -> string().
get_resource(Args, Default) ->
    maybe_binary_to_list(get_option(wspath, Args, Default)).

-spec get_legacy_ws(list(), boolean()) -> boolean().
get_legacy_ws(Args, Default) ->
    get_option(wslegacy, Args, Default).

-spec maybe_binary_to_list(binary() | string()) -> string().
maybe_binary_to_list(B) when is_binary(B) -> binary_to_list(B);
maybe_binary_to_list(S) when is_list(S) -> S.

-spec get_option(any(), list(), any()) -> any().
get_option(Key, Opts, Default) ->
    case lists:keyfind(Key, 1, Opts) of
        false -> Default;
        {Key, Value} -> Value
    end.

close_compression_streams(false) ->
    ok;
close_compression_streams({zlib, {Zin, Zout}}) ->
    try
        zlib:deflate(Zout, <<>>, finish),
        ok = zlib:inflateEnd(Zin),
        ok = zlib:deflateEnd(Zout)
    catch
        error:data_error -> ok
    after
        ok = zlib:close(Zin),
        ok = zlib:close(Zout)
    end.

stream_start_req(Props) ->
    {server, Server} = lists:keyfind(server, 1, Props),
    case proplists:get_value(wslegacy, Props, false) of
        true ->
            NS = proplists:get_value(stream_ns, Props, <<"jabber:client">>),
            escalus_stanza:stream_start(Server, NS);
        false ->
            escalus_stanza:ws_open(Server)
    end.

stream_end_req(Props) ->
    case proplists:get_value(wslegacy, Props, false) of
        true -> escalus_stanza:stream_end();
        false -> escalus_stanza:ws_close()
    end.

assert_stream_start(StreamStartRep, Props) ->
    case {StreamStartRep, proplists:get_value(wslegacy, Props, false)} of
        {#xmlel{name = <<"open">>}, false} ->
            StreamStartRep;
        {#xmlel{name = <<"open">>}, true} ->
            error("<open/> with legacy WebSocket",
                  [StreamStartRep]);
        {#xmlstreamstart{}, false} ->
            error("<stream:stream> with non-legacy WebSocket",
                  [StreamStartRep]);
        {#xmlstreamstart{}, _} ->
            StreamStartRep;
        _ ->
            error("Not a valid stream start", [StreamStartRep])
    end.

assert_stream_end(StreamEndRep, Props) ->
    case {StreamEndRep, proplists:get_value(wslegacy, Props, false)} of
        {#xmlel{name = <<"close">>}, false} ->
            StreamEndRep;
        {#xmlel{name = <<"close">>}, true} ->
            error("<close/> with legacy WebSocket",
                  [StreamEndRep]);
        {#xmlstreamend{}, false} ->
            error("<stream:stream> with non-legacy WebSocket",
                  [StreamEndRep]);
        {#xmlstreamend{}, _} ->
            StreamEndRep;
        _ ->
            error("Not a valid stream end", [StreamEndRep])
    end.

