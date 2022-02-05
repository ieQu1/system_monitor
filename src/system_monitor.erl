%% -*- mode: erlang -*-
%%--------------------------------------------------------------------------------
%% Copyright 2022 k32
%% Copyright 2021 Klarna Bank AB
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------------------
%% @private
-module(system_monitor).

-behaviour(gen_server).

%%--------------------------------------------------------------------
%% Include files
%%--------------------------------------------------------------------

-include_lib("system_monitor/include/system_monitor.hrl").

-include_lib("kernel/include/logger.hrl").

%% API
-export([ start_link/0
        , get_app_top/0
        , get_abs_app_top/0
        , get_app_memory/0
        , get_app_processes/0
        , get_function_top/0
        , get_proc_top/0
        , get_proc_info/1
        ]).

-export([reset/0]).

%% gen_server callbacks
-export([ init/1
        , handle_continue/2
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        ]).

%% Internal exports
-export([report_data/2]).

-include_lib("kernel/include/logger.hrl").

-define(SERVER, ?MODULE).
-define(TICK_INTERVAL, 1000).

-record(state, { monitors = []
               , timer_ref
               , last_ts               :: integer()
               , proc_top         = [] :: [#erl_top{}]
               , app_top          = [] :: [#app_top{}]
               , init_call_top    = [] :: function_top()
               , current_fun_top  = [] :: function_top()
               }).

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() -> gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Reset monitors
-spec reset() -> ok.
reset() ->
  gen_server:cast(?SERVER, reset).

%% @doc Get Erlang process top
-spec get_proc_top() -> {integer(), [#erl_top{}]}.
get_proc_top() ->
  {ok, Data} = gen_server:call(?SERVER, get_proc_top, infinity),
  Data.

%% @doc Get Erlang process top info for one process
-spec get_proc_info(pid() | atom()) -> #erl_top{} | false.
get_proc_info(Name) when is_atom(Name) ->
  case whereis(Name) of
    undefined -> false;
    Pid       -> get_proc_info(Pid)
  end;
get_proc_info(Pid) ->
  gen_server:call(?SERVER, {get_proc_top, Pid}, infinity).

%% @doc Get relative reduction utilization per application, sorted by
%% reductions
-spec get_app_top() -> [{atom(), float()}].
get_app_top() ->
  do_get_app_top(#app_top.red_rel).

%% @doc Get absolute reduction utilization per application, sorted by
%% reductions
-spec get_abs_app_top() -> [{atom(), integer()}].
get_abs_app_top() ->
  do_get_app_top(#app_top.red_abs).

%% @doc Get memory utilization per application, sorted by memory
-spec get_app_memory() -> [{atom(), integer()}].
get_app_memory() ->
  do_get_app_top(#app_top.memory).

%% @doc Get number of processes spawned by each application
-spec get_app_processes() -> [{atom(), integer()}].
get_app_processes() ->
  do_get_app_top(#app_top.processes).

%% @doc Get approximate distribution of initilal_call and
%% current_function per process
-spec get_function_top() -> #{ initial_call     := function_top()
                             , current_function := function_top()
                             }.
get_function_top() ->
  {ok, Data} = gen_server:call(?SERVER, get_function_top, infinity),
  Data.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
  {ok, Timer} = timer:send_interval(?TICK_INTERVAL, {self(), tick}),
  State = #state{ monitors  = init_monitors()
                , timer_ref = Timer
                , last_ts   = system_monitor_collector:timestamp()
                },
  {ok, State, {continue, start_callback}}.

handle_continue(start_callback, State) ->
  case system_monitor_callback:is_configured() of
    true -> ok = system_monitor_callback:start();
    false -> ok
  end,
  {noreply, State}.

handle_call(get_proc_top, _From, State) ->
  Top = State#state.proc_top,
  SnapshotTS = State#state.last_ts,
  Data = {SnapshotTS, Top},
  {reply, {ok, Data}, State};
handle_call({get_proc_top, Pid}, _From, State) ->
  Top = State#state.proc_top,
  {reply, lists:keyfind(pid_to_list(Pid), #erl_top.pid, Top), State};
handle_call(get_app_top, _From, State) ->
  Data = State#state.app_top,
  {reply, {ok, Data}, State};
handle_call(get_function_top, _From, State) ->
  Data = #{ initial_call     => State#state.init_call_top
          , current_function => State#state.current_fun_top
          },
  {reply, {ok, Data}, State};
handle_call({report_data, SnapshotTS, ProcTop, AppTop, InitCallTop, CurrentFunTop}, _From, State) ->
  {reply, ok, State#state{ last_ts         = SnapshotTS
                         , proc_top        = ProcTop
                         , app_top         = AppTop
                         , init_call_top   = InitCallTop
                         , current_fun_top = CurrentFunTop
                         }};
handle_call(_Request, _From, State) ->
  {reply, {error, unknown_call}, State}.

handle_cast(reset, State) ->
  {noreply, State#state{monitors = init_monitors()}};
handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info({Self, tick}, State) when Self =:= self() ->
  Monitors = [case Ticks - 1 of
                0 ->
                  try
                    apply(Module, Function, [])
                  catch
                    EC:Error:Stack ->
                      error_logger:warning_msg(
                        "system_monitor ~p crashed:~n~p:~p~nStacktrace: ~p~n",
                        [{Module, Function}, EC, Error, Stack])
                  end,
                  {Module, Function, RunOnTerminate, TicksReset, TicksReset};
                TicksDecremented ->
                  {Module, Function, RunOnTerminate, TicksReset, TicksDecremented}
              end || {Module, Function,
                      RunOnTerminate, TicksReset, Ticks} <- State#state.monitors],
  {noreply, State#state{monitors = Monitors}};
handle_info(_Info, State) ->
  {noreply, State}.

-spec terminate(term(), #state{}) -> any().
terminate(_Reason, State) ->
  %% Possibly, one last check.
  [apply(?MODULE, Monitor, []) ||
    {Monitor, true, _TicksReset, _Ticks} <- State#state.monitors].

%%====================================================================
%% Internal exports
%%====================================================================

report_data(SnapshotTS, {ProcTop, AppTop, InitCallTop, CurrentFunTop}) ->
  gen_server:call(?SERVER, {report_data, SnapshotTS, ProcTop, AppTop, InitCallTop, CurrentFunTop}).

%%==============================================================================
%% Internal functions
%%==============================================================================

%% @doc Return the list of initiated monitors.
-spec init_monitors() -> [{module(), function(), boolean(), pos_integer(), pos_integer()}].
init_monitors() ->
  [{Module, Function, RunOnTerminate, Ticks, Ticks}
   || {Module, Function, RunOnTerminate, Ticks} <- monitors()].

%% @doc Returns the list of monitors. The format is
%%
%% ```{FunctionName, RunMonitorAtTerminate, NumberOfTicks}'''
%%
%% `RunMonitorAtTerminate' determines whether the monitor is to be run
%% in the terminate gen_server callback.  ... and `NumberOfTicks' is
%% the number of ticks between invocations of the monitor in
%% question. So, if `NumberOfTicks' is 3600, the monitor is to be run
%% once every hour, as there is a tick every second.
-spec monitors() -> [{module(), function(), boolean(), pos_integer()}].
monitors() ->
  {ok, AdditionalMonitors} = application:get_env(system_monitor, status_checks),
  MaybeReportFullStatusMonitor =
    case system_monitor_callback:is_configured() of
      true ->
        {ok, TopInterval} = application:get_env(?APP, top_sample_interval),
        [{?MODULE, report_full_status, false, TopInterval div 1000}];
      false ->
        []
    end,
  MaybeReportFullStatusMonitor
  ++ AdditionalMonitors.

%%------------------------------------------------------------------------------
%% Monitor for number of processes
%%------------------------------------------------------------------------------

-spec do_get_app_top(integer()) -> [{atom(), number()}].
do_get_app_top(FieldId) ->
  {ok, Data} = gen_server:call(?SERVER, get_app_top, infinity),
  lists:reverse(
    lists:keysort(2, [{Val#app_top.app, element(FieldId, Val)}
                      || Val <- Data])).
