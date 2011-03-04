-module(escalus_story).

% Public API
-export([story/3]).

-include_lib("test_server/include/test_server.hrl").

%%--------------------------------------------------------------------
%% Public API
%%--------------------------------------------------------------------

story(Config, ResourceCounts, Test) ->
    UserSpecs = escalus_users:get_users(all),
    Clients = [start_clients(Config, UserSpec, ResCount) ||
               {{_, UserSpec}, ResCount} <- lists:zip(UserSpecs,
                                                 ResourceCounts)],
    ClientList = lists:flatten(Clients),
    prepare_clients(Config, ClientList),
    apply(Test, ClientList).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

start_clients(Config, UserSpec, ResourceCount) ->
    [start_client(Config, UserSpec, ResNo) ||
     ResNo <- lists:seq(1, ResourceCount)].

start_client(Config, UserSpec, ResNo) ->
    escalus_client:start_wait(Config, UserSpec,
                              "res" ++ integer_to_list(ResNo)).

prepare_clients(Config, ClientList) ->
    case proplists:get_bool(escalus_save_initial_history, Config) of
        true ->
            do_nothing;
        false ->
            lists:foreach(fun escalus_client:drop_history/1, ClientList)
    end.