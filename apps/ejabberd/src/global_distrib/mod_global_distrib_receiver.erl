%%==============================================================================
%% Copyright 2017 Erlang Solutions Ltd.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%==============================================================================

-module(mod_global_distrib_receiver).
-author('konrad.zemek@erlang-solutions.com').

-behaviour(gen_mod).
-behaviour(ranch_protocol).
-behaviour(gen_server).

-include("ejabberd.hrl").
-include("jlib.hrl").
-include("global_distrib_metrics.hrl").

-export([endpoints/0, start_link/4]).
-export([start/2, stop/1]).
-export([init/1, handle_info/2, handle_cast/2, handle_call/3, code_change/3, terminate/2]).

-record(state, {
    socket :: fast_tls:tls_socket(),
    waiting_for :: header | non_neg_integer(),
    buffer = <<>> :: binary()
}).

-type state() :: #state{}.

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-spec start_link(Ref :: reference(), Socket :: gen_tcp:socket(), Transport :: ranch_tcp,
                 Opts :: [term()]) -> {ok, pid()}.
start_link(Ref, Socket, ranch_tcp, Opts) ->
    Pid = proc_lib:spawn_link(?MODULE, init, [{Ref, Socket, Opts}]),
    {ok, Pid}.

%%--------------------------------------------------------------------
%% gen_mod API
%%--------------------------------------------------------------------

-spec start(Host :: ejabberd:lserver(), Opts :: proplists:proplist()) -> any().
start(Host, Opts0) ->
    {local_host, LocalHost} = lists:keyfind(local_host, 1, Opts0),
    Opts = [{endpoints, [{LocalHost, 5555}]}, {num_of_workers, 10} | Opts0],
    mod_global_distrib_utils:start(?MODULE, Host, Opts, fun start/0).

-spec stop(Host :: ejabberd:lserver()) -> any().
stop(Host) ->
    mod_global_distrib_utils:stop(?MODULE, Host, fun stop/0).

%%--------------------------------------------------------------------
%% ranch_protocol API
%%--------------------------------------------------------------------

init({Ref, Socket, _Opts}) ->
    ok = ranch:accept_ack(Ref),
    {ok, TLSSocket} = fast_tls:tcp_to_tls(Socket, opt(tls_opts)),
    ok = fast_tls:setopts(TLSSocket, [{active, once}]),
    gen_server:enter_loop(?MODULE, [], #state{socket = TLSSocket,
                                              waiting_for = header}).

%%--------------------------------------------------------------------
%% gen_server API
%%--------------------------------------------------------------------

handle_info({tcp, _Socket, TLSData}, #state{socket = Socket, buffer = Buffer} = State) ->
    ok = fast_tls:setopts(Socket, [{active, once}]),
    {ok, Data} = fast_tls:recv_data(Socket, TLSData),
    NewState = handle_buffered(State#state{buffer = <<Buffer/binary, Data/binary>>}),
    {noreply, NewState};
handle_info({tcp_closed, _Socket}, #state{socket = Socket} = State) ->
    fast_tls:close(Socket),
    {stop, normal, State}.

handle_cast(_Message, _State) ->
    exit(bad_cast).

handle_call(_Message, _From, _State) ->
    exit(bad_call).

code_change(_Version, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ignore.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

-spec start() -> any().
start() ->
    opt(tls_opts), %% Check for required tls_opts
    mongoose_metrics:ensure_metric(global, ?GLOBAL_DISTRIB_MESSAGES_RECEIVED, spiral),
    mongoose_metrics:ensure_metric(global, ?GLOBAL_DISTRIB_RECV_QUEUE_TIME, histogram),
    ChildMod = mod_global_distrib_worker_sup,
    Child = {ChildMod, {ChildMod, start_link, []}, permanent, 10000, supervisor, [ChildMod]},
    {ok, _}= supervisor:start_child(ejabberd_sup, Child),
    Endpoints = mod_global_distrib_utils:resolve_endpoints(opt(endpoints)),
    ets:insert(?MODULE, {endpoints, Endpoints}),
    start_listeners().

-spec stop() -> any().
stop() ->
    stop_listeners(),
    supervisor:terminate_child(ejabberd_sup, mod_global_distrib_worker_sup),
    supervisor:delete_child(ejabberd_sup, mod_global_distrib_worker_sup).

-spec opt(Key :: atom()) -> term().
opt(Key) ->
    mod_global_distrib_utils:opt(?MODULE, Key).

-spec handle_data(Data :: binary(), state()) -> ok.
handle_data(Data, #state{}) ->
    <<BinFromSize:16, _/binary>> = Data,
    <<_:16, BinFrom:BinFromSize/binary, BinTerm/binary>> = Data,
    Worker = mod_global_distrib_worker_sup:get_worker(BinFrom),
    Stamp = erlang:monotonic_time(),
    ok = mod_global_distrib_utils:cast_or_call(Worker, {data, Stamp, BinTerm}).

-spec handle_buffered(state()) -> state().
handle_buffered(#state{waiting_for = header, buffer = <<Header:4/binary, Rest/binary>>} = State) ->
    Size = binary:decode_unsigned(Header),
    handle_buffered(State#state{waiting_for = Size, buffer = Rest});
handle_buffered(#state{waiting_for = Size, buffer = Buffer} = State)
  when byte_size(Buffer) >= Size ->
    <<Data:Size/binary, Rest/binary>> = Buffer,
    handle_data(Data, State),
    handle_buffered(State#state{waiting_for = header, buffer = Rest});
handle_buffered(State) ->
    State.

-spec endpoints() -> [mod_global_distrib_utils:endpoint()].
endpoints() ->
    opt(endpoints).

-spec start_listeners() -> any().
start_listeners() ->
    lists:foreach(fun start_listener/1, endpoints()).

-spec start_listener(mod_global_distrib_utils:endpoint()) -> any().
start_listener({Addr, Port} = Ref) ->
    ?INFO_MSG("Starting listener on ~s:~b", [inet:ntoa(Addr), Port]),
    {ok, _} = ranch:start_listener(Ref, 10, ranch_tcp, [{ip, Addr}, {port, Port}],
                                   ?MODULE, []).

-spec stop_listeners() -> any().
stop_listeners() ->
    lists:foreach(fun ranch:stop_listener/1, endpoints()).

