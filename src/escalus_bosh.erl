%%%===================================================================
%%% @copyright (C) 2011-2012, Erlang Solutions Ltd.
%%% @doc Module abstracting TCP connection to XMPP server
%%% @end
%%%===================================================================

-module(escalus_bosh).
-behaviour(gen_server).
-behaviour(escalus_connection).

-include_lib("exml/include/exml_stream.hrl").
-include("escalus.hrl").
-include("escalus_xmlns.hrl").

%% Escalus transport callbacks
-export([connect/1,
         send/2,
         is_connected/1,
         upgrade_to_tls/1,
         use_zlib/1,
         reset_parser/1,
         stop/1,
         kill/1,
         set_filter_predicate/2,
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

%% BOSH XML elements
-export([session_creation_body/2, session_creation_body/6,
         session_termination_body/2,
         empty_body/2, empty_body/3]).

%% Low level API
-export([send_raw/2,
         resend_raw/2,
         get_sid/1,
         get_rid/1,
         get_keepalive/1,
         set_keepalive/2,
         mark_as_terminated/1,
         pause/2,
         get_active/1,
         set_active/2,
         recv/1,
         get_requests/1]).

-define(WAIT_FOR_SOCKET_CLOSE_TIMEOUT, 200).
-define(SERVER, ?MODULE).
-define(DEFAULT_WAIT, 60).

-record(state, {owner,
                url,
                parser,
                sid = nil,
                rid = nil,
                requests = [],
                keepalive = true,
                wait,
                active = true,
                replies = [],
                terminated = false,
                event_client,
                client,
                on_reply,
                filter_pred}).

%%%===================================================================
%%% API
%%%===================================================================

-spec connect([{atom(), any()}]) -> pid().
connect(Args) ->
    {ok, Pid} = gen_server:start_link(?MODULE, [Args, self()], []),
    Pid.

send(Pid, Elem) ->
    gen_server:call(Pid, {send, Elem}).

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
    try
        mark_as_terminated(Pid),
        gen_server:call(Pid, stop)
    catch
        exit:{noproc, {gen_server, call, _}} ->
            already_stopped;
        exit:{normal, {gen_server, call, _}} ->
            already_stopped
    end.

upgrade_to_tls(_Client) ->
    error(not_supported).

use_zlib(_Client) ->
    error(not_supported).

-spec set_filter_predicate(pid(), escalus_connection:filter_pred()) -> ok.
set_filter_predicate(Pid, Pred) ->
    gen_server:call(Pid, {set_filter_pred, Pred}).

%%%===================================================================
%%% BOSH XML elements
%%%===================================================================

session_creation_body(Rid, To) ->
    session_creation_body(?DEFAULT_WAIT, <<"1.0">>, <<"en">>, Rid, To, nil).

session_creation_body(Wait, Version, Lang, Rid, To, nil) ->
    empty_body(Rid, nil,
               [{<<"content">>, <<"text/xml; charset=utf-8">>},
                {<<"xmlns:xmpp">>, ?NS_BOSH},
                {<<"xmpp:version">>, Version},
                {<<"ver">>, <<"1.6">>},
                {<<"hold">>, <<"1">>},
                {<<"wait">>, list_to_binary(integer_to_list(Wait))},
                {<<"xml:lang">>, Lang},
                {<<"to">>, To}]);

session_creation_body(_Wait, _Version, Lang, Rid, To, Sid) ->
    empty_body(Rid, Sid,
                [{<<"xmlns:xmpp">>, ?NS_BOSH},
                 {<<"xml:lang">>, Lang},
                 {<<"to">>, To},
                 {<<"xmpp:restart">>, <<"true">>}]).

session_termination_body(Rid, Sid) ->
    Body = empty_body(Rid, Sid, [{<<"type">>, <<"terminate">>}]),
    Body#xmlel{children = [escalus_stanza:presence(<<"unavailable">>)]}.

empty_body(Rid, Sid) ->
    empty_body(Rid, Sid, []).

empty_body(Rid, Sid, ExtraAttrs) ->
    #xmlel{name = <<"body">>,
           attrs = common_attrs(Rid, Sid) ++ ExtraAttrs}.

pause_body(Rid, Sid, Seconds) ->
    Empty = empty_body(Rid, Sid),
    Pause = {<<"pause">>, integer_to_binary(Seconds)},
    Empty#xmlel{attrs = Empty#xmlel.attrs ++ [Pause]}.

common_attrs(Rid) ->
    [{<<"rid">>, pack_rid(Rid)},
     {<<"xmlns">>, ?NS_HTTP_BIND}].

common_attrs(Rid, nil) ->
    common_attrs(Rid);
common_attrs(Rid, Sid) ->
    common_attrs(Rid) ++ [{<<"sid">>, Sid}].

pack_rid(Rid) ->
    integer_to_binary(Rid).

%%%===================================================================
%%% Low level API
%%%===================================================================

%% Watch out for request IDs!
%%
%% In general, you should not use this function,
%% as this transport (i.e. escalus_bosh) takes care
%% of wrapping ordinary XMPP stanzas for you.
%%
%% However, in case of the need for a low-level access interleaving
%% calls to send/2 and send_raw/2 is tricky.
%% For send/2 the transport keeps track of an internal
%% request ID which might not necessarily be consistent with the one supplied
%% when manually building the BOSH body and sending it with send_raw/2.
%% Always use get_rid/1 which will give you a valid request ID to use
%% when manually wrapping stanzas to send_raw/2.
%%
%% Otherwise, the non-matching request IDs will
%% confuse the server and possibly cause errors.
send_raw(Pid, Body) ->
    gen_server:cast(Pid, {send_raw, Body}).

%% This is much like send_raw/2 except for the fact that
%% the request ID won't be autoincremented on send.
%% I.e. it is intended for resending packets which were
%% already sent.
resend_raw(Pid, Body) ->
    gen_server:cast(Pid, {resend_raw, Body}).

get_rid(Pid) ->
    gen_server:call(Pid, get_rid).

get_sid(Pid) ->
    gen_server:call(Pid, get_sid).

get_keepalive(Pid) ->
    gen_server:call(Pid, get_keepalive).

set_keepalive(Pid, NewKeepalive) ->
    gen_server:call(Pid, {set_keepalive, NewKeepalive}).

mark_as_terminated(Pid) ->
    gen_server:call(Pid, mark_as_terminated).

pause(Pid, Seconds) ->
    gen_server:cast(Pid, {pause, Seconds}).

%% get_-/set_active tries to tap into the intuition gained from using
%% inet socket option {active, true | false | once}.
%% An active BOSH transport sends unpacked stanzas to an escalus client,
%% where they can be received using wait_for_stanzas.
%% An inactive BOSH transport buffers the stanzas in its state.
%% They can be retrieved using escalus_bosh:recv.
%%
%% Sometimes it's necessary to intercept the whole BOSH wrapper
%% not only the wrapped stanzas. That's when this mechanism proves useful.
get_active(Pid) ->
    gen_server:call(Pid, get_active).

set_active(Pid, Active) ->
    gen_server:call(Pid, {set_active, Active}).

-spec recv(escalus:client()) -> exml_stream:element() | empty.
recv(Pid) ->
    gen_server:call(Pid, recv).

get_requests(Pid) ->
    gen_server:call(Pid, get_requests).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% TODO: refactor all opt defaults taken from Args into a default_opts function,
%%       so that we know what options the module actually expects
init([Args, Owner]) ->
    Host = proplists:get_value(host, Args, <<"localhost">>),
    Port = proplists:get_value(port, Args, 5280),
    Path = proplists:get_value(path, Args, <<"/http-bind">>),
    Wait = proplists:get_value(bosh_wait, Args, ?DEFAULT_WAIT),
    HTTPS = proplists:get_value(ssl, Args, false),
    EventClient = proplists:get_value(event_client, Args),
    HostStr = host_to_list(Host),
    OnReplyFun = proplists:get_value(on_reply, Args, fun(_) -> ok end),
    OnConnectFun = proplists:get_value(on_connect, Args, fun(_) -> ok end),
    {MS, S, MMS} = now(),
    InitRid = MS * 1000000 * 1000000 + S * 1000000 + MMS,
    {ok, Parser} = exml_stream:new_parser(),
    {ok, Client} = fusco_cp:start_link({HostStr, Port, HTTPS},
                                       [{on_connect, OnConnectFun}],
                                       %% Max two connections as per BOSH rfc
                                       2),
    {ok, #state{owner = Owner,
                url = Path,
                parser = Parser,
                rid = InitRid,
                keepalive = proplists:get_value(keepalive, Args, true),
                wait = Wait,
                event_client = EventClient,
                client = Client,
                on_reply = OnReplyFun}}.

handle_call(get_sid, _From, #state{sid = Sid} = State) ->
    {reply, Sid, State};

handle_call(get_rid, _From, #state{rid = Rid} = State) ->
    {reply, Rid, State};

handle_call(get_keepalive, _From, #state{keepalive = Keepalive} = State) ->
    {reply, Keepalive, State};
handle_call({set_keepalive, NewKeepalive}, _From,
            #state{keepalive = Keepalive} = State) ->
    {reply, {ok, Keepalive, NewKeepalive},
     State#state{keepalive = NewKeepalive}};

handle_call(mark_as_terminated, _From, #state{} = State) ->
    {reply, {ok, marked_as_terminated}, State#state{terminated=true}};

handle_call(get_active, _From, #state{active = Active} = State) ->
    {reply, Active, State};
handle_call({set_active, Active}, _From, State) ->
    {reply, ok, State#state{active = Active}};

handle_call({send, Elem}, _From, State) ->
    NewState = send_elem(Elem, State),
    {reply, ok, NewState};

handle_call(recv, _From, State) ->
    {Reply, NS} = handle_recv(State),
    {reply, Reply, NS};

handle_call(get_requests, _From, State) ->
    {reply, length(State#state.requests), State};

handle_call({set_filter_pred, Pred}, _From, State) ->
    {reply, ok, State#state{filter_pred = Pred}};

handle_call(stop, _From, #state{} = State) ->
    {stop, normal, ok, State}.

handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast({send_raw, Body}, State) ->
    NewState = send_data(Body, State),
    {noreply, NewState};
handle_cast({resend_raw, Body}, State) ->
    NewState = send_data(Body, State#state.rid, State),
    {noreply, NewState};
handle_cast({pause, Seconds},
            #state{rid = Rid, sid = Sid} = State) ->
    NewState = send_data(pause_body(Rid, Sid, Seconds), State),
    {noreply, NewState};
handle_cast(reset_parser, #state{parser = Parser} = State) ->
    {ok, NewParser} = exml_stream:reset_parser(Parser),
    {noreply, State#state{parser = NewParser}}.


%% Handle async HTTP request replies.
handle_info({http_reply, Ref, Body}, S) ->
    NewRequests = lists:keydelete(Ref, 1, S#state.requests),
    {ok, #xmlel{attrs=Attrs} = XmlBody} = exml:parse(Body),
    NS = handle_data(XmlBody, S#state{requests = NewRequests}),
    NNS = case {detect_type(Attrs), NS#state.keepalive, NS#state.requests == []}
          of
              {streamend, _, _} -> close_requests(NS#state{terminated=true});
              {_, false, _}     -> NS;
              {_, true, true}   -> send_data(empty_body(NS#state.rid, NS#state.sid), NS);
              {_, true, false}  -> NS
    end,
    {noreply, NNS};
handle_info(_, State) ->
    {noreply, State}.


terminate(_Reason, #state{client = Client, parser = Parser}) ->
    fusco_cp:stop(Client),
    exml_stream:free_parser(Parser).


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%%===================================================================
%%% Helpers
%%%===================================================================

request(Client, Path, Body, OnReplyFun) ->
    Headers = [{<<"Content-Type">>, <<"text/xml; charset=utf-8">>}],
    Reply =
        fusco_cp:request(Client, Path, "POST", Headers, exml:to_iolist(Body),
                         2, infinity),
    OnReplyFun(Reply),
    {ok, {_Status, _Headers, RBody, _Size, _Time}} = Reply,
    {ok, RBody}.

close_requests(#state{requests=Reqs} = S) ->
    [exit(Pid, normal) || {_Ref, Pid} <- Reqs],
    S#state{requests=[]}.

send_data(Body, State) ->
    send_data(Body, State#state.rid+1, State).

send_data(_, _, #state{terminated = true} = S) ->
    %% Sending anything to a terminated session is pointless.
    %% We leave it in its current state to pick up any pending replies.
    S;
send_data(Body, NewRid, #state{client = Client, url = Path, on_reply = OnReplyFun,
                          requests = Requests} = S) ->
    Ref = make_ref(),
    Self = self(),
    AsyncReq = fun() ->
            {ok, Reply} = request(Client, Path, Body, OnReplyFun),
            Self ! {http_reply, Ref, Reply}
    end,
    NewRequests = [{Ref, proc_lib:spawn_link(AsyncReq)} | Requests],
    S#state{rid = NewRid, requests = NewRequests}.

send_elem(Elem, State) ->
    send_data(wrap_elem(Elem, State), State).

handle_data(#xmlel{} = Body, #state{} = State) ->
    NewState = case State#state.sid of
        %% First reply for this transport, set sid
        nil ->
            State#state{sid = exml_query:attr(Body, <<"sid">>)};
        _ ->
            State
    end,
    Stanzas = unwrap_elem(Body),
    case State#state.active of
        true ->
            escalus_connection:maybe_forward_to_owner(NewState#state.filter_pred,
                                                      NewState, Stanzas,
                                                      fun forward_to_owner/2),
            NewState;
        false ->
            store_reply(Body, NewState)
    end.

forward_to_owner(Stanzas, #state{owner = Owner,
                                 event_client = EventClient}) ->
    lists:foreach(fun(Stanza) ->
        escalus_event:incoming_stanza(EventClient, Stanza),
        Owner ! {stanza, self(), Stanza}
    end, Stanzas),
    case lists:keyfind(xmlstreamend, 1, Stanzas) of
        false ->
            ok;
        _ ->
            gen_server:cast(self(), stop)
    end.

store_reply(Body, #state{replies = Replies} = S) ->
    S#state{replies = Replies ++ [Body]}.

handle_recv(#state{replies = []} = S) ->
    {empty, S};
handle_recv(#state{replies = [Reply | Replies]} = S) ->
    case Reply of
        #xmlstreamend{} ->
            gen_server:cast(self(), stop);
        _ -> ok
    end,
    {Reply, S#state{replies = Replies}}.

wrap_elem(#xmlstreamstart{attrs = Attrs},
          #state{rid = Rid, sid = Sid, wait = Wait}) ->
    Version = proplists:get_value(<<"version">>, Attrs, <<"1.0">>),
    Lang = proplists:get_value(<<"xml:lang">>, Attrs, <<"en">>),
    To = proplists:get_value(<<"to">>, Attrs, <<"localhost">>),
    session_creation_body(Wait, Version, Lang, Rid, To, Sid);
wrap_elem(#xmlstreamend{}, #state{sid=Sid, rid=Rid}) ->
    session_termination_body(Rid, Sid);
wrap_elem(Element, #state{sid = Sid, rid=Rid}) ->
    (empty_body(Rid, Sid))#xmlel{children = [Element]}.

unwrap_elem(#xmlel{name = <<"body">>, children = Body, attrs=Attrs}) ->
    Type = detect_type(Attrs),
    case Type of
        {streamstart, Ver} ->
            Server = proplists:get_value(<<"from">>, Attrs),
            StreamStart = #xmlstreamstart{name = <<"stream:stream">>, attrs=[
                        {<<"from">>, Server},
                        {<<"version">>, Ver},
                        {<<"xml:lang">>, <<"en">>},
                        {<<"xmlns">>, <<"jabber:client">>},
                        {<<"xmlns:stream">>,
                         <<"http://etherx.jabber.org/streams">>}]},
            [StreamStart];
        streamend ->
            [escalus_stanza:stream_end()];
        _ -> []
    end ++ Body.

detect_type(Attrs) ->
    Get = fun(A) -> proplists:get_value(A, Attrs) end,
    case {Get(<<"type">>), Get(<<"xmpp:version">>)} of
        {<<"terminate">>, _} -> streamend;
        {_,       undefined} -> normal;
        {_,         Version} -> {streamstart,Version}
    end.

host_to_list({_,_,_,_} = IP4) -> inet_parse:ntoa(IP4);
host_to_list({_,_,_,_,_,_,_,_} = IP6) -> inet_parse:ntoa(IP6);
host_to_list(BHost) when is_binary(BHost) -> binary_to_list(BHost);
host_to_list(Host) when is_list(Host) -> Host.

stream_start_req(Props) ->
    {server, Server} = lists:keyfind(server, 1, Props),
    NS = proplists:get_value(stream_ns, Props, <<"jabber:client">>),
    escalus_stanza:stream_start(Server, NS).

stream_end_req(_) ->
    escalus_stanza:stream_end().

assert_stream_start(Rep = #xmlstreamstart{}, _) -> Rep;
assert_stream_start(Rep, _) -> error("Not a valid stream start", [Rep]).

assert_stream_end(Rep = #xmlstreamend{}, _) -> Rep;
assert_stream_end(Rep, _) -> error("Not a valid stream end", [Rep]).
