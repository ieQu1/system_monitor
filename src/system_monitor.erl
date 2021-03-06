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

-include("sysmon_int.hrl").

-include_lib("kernel/include/logger.hrl").

%% API
-export([ start_link/0
        , reset/0

        , get_app_top/0
        , get_abs_app_top/0
        , get_app_memory/0
        , get_app_processes/0
        , get_function_top/0
        , get_proc_top/0
        , get_proc_info/1

        , add_vip/1
        , remove_vip/1
        ]).

%% Builtin checks
-export([ check_process_count/0
        , suspect_procs/0
        ]).

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

-export_type([ function_top/0
             ]).

-include_lib("kernel/include/logger.hrl").

-define(SERVER, ?MODULE).
-define(TABLE, system_monitor_data_tab).

-type function_top() :: [{mfa(), number()}].

-record(state, { monitors = []
               , timer_ref
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

%% @doc Add a VIP
-spec add_vip(atom() | [atom()]) -> ok.
add_vip(NameOrNames) ->
  system_monitor_collector:add_vip(NameOrNames).

%% @doc Add a VIP
-spec remove_vip(atom()) -> ok.
remove_vip(RegName) ->
  system_monitor_collector:remove_vip(RegName).

%% @doc Get Erlang process top
-spec get_proc_top() -> [#erl_top{}].
get_proc_top() ->
  lookup_top(proc_top).

%% @doc Get Erlang process top info for one process
-spec get_proc_info(pid() | atom()) -> #erl_top{} | false.
get_proc_info(Name) when is_atom(Name) ->
  case whereis(Name) of
    undefined -> false;
    Pid       -> get_proc_info(Pid)
  end;
get_proc_info(Pid) ->
  Top = lookup_top(proc_top),
  lists:keyfind(pid_to_list(Pid), #erl_top.pid, Top).

%% @doc Get relative reduction utilization per application, sorted by
%% reductions
-spec get_app_top() -> [{atom(), float()}].
get_app_top() ->
  get_filtered_top(app_top, #app_top.app, #app_top.red_rel, reductions).

%% @doc Get absolute reduction utilization per application, sorted by
%% reductions
-spec get_abs_app_top() -> [{atom(), integer()}].
get_abs_app_top() ->
  get_filtered_top(app_top, #app_top.app, #app_top.red_abs, abs_reductions).

%% @doc Get memory utilization per application, sorted by memory
-spec get_app_memory() -> [{atom(), integer()}].
get_app_memory() ->
  get_filtered_top(app_top, #app_top.app, #app_top.memory, memory).

%% @doc Get number of processes spawned by each application
-spec get_app_processes() -> [{atom(), integer()}].
get_app_processes() ->
  get_filtered_top(app_top, #app_top.app, #app_top.processes, num_processes).

%% @doc Get approximate distribution of initilal_call and
%% current_function per process
-spec get_function_top() -> #{ initial_call     := function_top()
                             , current_function := function_top()
                             }.
get_function_top() ->
  #{ initial_call     => get_filtered_top(init_call_top, 1, 2, initial_call)
   , current_function => get_filtered_top(current_fun_top, 1, 2, current_function)
   }.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
  process_flag(trap_exit, true),
  logger:update_process_metadata(#{domain => [system_monitor, status_check]}),
  ets:new(?TABLE, [ public
                  , named_table
                  , set
                  , {keypos, 1}
                  , {write_concurrency, false}
                  ]),
  {ok, Timer} = timer:send_interval(?CFG(tick_interval), {self(), tick}),
  State = #state{ monitors  = init_monitors()
                , timer_ref = Timer
                },
  {ok, State, {continue, start_callback}}.

handle_continue(start_callback, State) ->
  ok = system_monitor_callback:start(),
  {noreply, State}.

handle_call(_Request, _From, State) ->
  {reply, {error, unknown_call}, State}.

handle_cast({report_data, SnapshotTS, ProcTop, AppTop, InitCallTop, CurrentFunTop}, State) ->
  ets:insert(?TABLE, {proc_top,        SnapshotTS, ProcTop}),
  ets:insert(?TABLE, {app_top,         SnapshotTS, AppTop}),
  ets:insert(?TABLE, {init_call_top,   SnapshotTS, InitCallTop}),
  ets:insert(?TABLE, {current_fun_top, SnapshotTS, CurrentFunTop}),
  report_node_status(SnapshotTS, ProcTop, AppTop),
  ?tp(sysmon_report_data, #{ts => SnapshotTS}),
  {noreply, State};
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
                      logger:debug(
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

%%================================================================================
%% Builtin checks
%%================================================================================

%% @doc Check the number of processes and log an aggregate summary of
%% the process info if the count is above Threshold.
-spec check_process_count() -> ok.
check_process_count() ->
  {ok, MaxProcs} = application:get_env(?APP, top_max_procs),
  case erlang:system_info(process_count) of
    Count when Count > MaxProcs div 5 ->
      ?tp(warning, "Abnormal process count", #{n_procs => Count});
    _ ->
      ok
  end.

suspect_procs() ->
  ProcTop = get_proc_top(),
  Conf = { ?CFG(suspect_procs_max_memory)
         , ?CFG(suspect_procs_max_message_queue_len)
         , ?CFG(suspect_procs_max_total_heap_size)
         },
  SuspectProcs = lists:filter(fun(Proc) -> is_suspect_proc(Proc, Conf) end, ProcTop),
  lists:foreach(fun log_suspect_proc/1, SuspectProcs).

%%====================================================================
%% Internal exports
%%====================================================================

report_data(SnapshotTS, {ProcTop, AppTop, InitCallTop, CurrentFunTop}) ->
  gen_server:cast(?SERVER, {report_data, SnapshotTS, ProcTop, AppTop, InitCallTop, CurrentFunTop}).

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
%% ```{Module, FunctionName, RunAtTerminate, NumberOfTicks}'''
%%
%% `RunMonitorAtTerminate' determines whether the monitor is to be run
%% in the terminate gen_server callback.  ... and `NumberOfTicks' is
%% the number of ticks between invocations of the monitor in
%% question. So, if `NumberOfTicks' is 3600, the monitor is to be run
%% once every hour, as there is a tick every second.
-spec monitors() -> [{module(), function(), boolean(), pos_integer()}].
monitors() ->
  ?CFG(status_checks).

%% @doc Report node status
report_node_status(TS, ProcTop, AppTop) ->
  system_monitor_callback:produce(proc_top, ProcTop),
  system_monitor_callback:produce(app_top, AppTop),
  produce_fun_top(TS),
  %% Node status report goes last, and it "seals" the report for this
  %% time interval:
  NodeReport =
    case application:get_env(?APP, node_status_fun) of
      {ok, {Module, Function}} ->
        try
          Module:Function()
        catch
          _:_ ->
            <<>>
        end;
      _ ->
        <<>>
    end,
  system_monitor_callback:produce(node_status,
                                  [{node_status, node(), TS, iolist_to_binary(NodeReport)}]).

-spec get_filtered_top(proc_top | app_top | init_call_top | current_fun_top, byte(), byte(), atom()) ->
        [{atom(), number()}].
get_filtered_top(Top, KeyField, ValueField, ThresholdKey) ->
  Threshold = maps:get(ThresholdKey, ?CFG(top_significance_threshold), 0.0001),
  lists:reverse(lists:keysort(2, lookup_top_kv(Top, KeyField, ValueField, Threshold))).

-spec lookup_top_kv(proc_top | app_top | init_call_top | current_fun_top, byte(), byte(), number()) ->
        [{atom(), number()}].
lookup_top_kv(Top, KeyField, ValueField, Threshold) ->
  lists:filtermap( fun(Record) ->
                       Key = element(KeyField, Record),
                       Val = element(ValueField, Record),
                       case Val > Threshold of
                         true  -> {true, {Key, Val}};
                         false -> false
                       end
                   end
                 , lookup_top(Top)
                 ).

-spec lookup_top(proc_top | app_top | init_call_top | current_fun_top) -> list().
lookup_top(Key) ->
  case ets:lookup(?TABLE, Key) of
    [{Key, _Timestamp, Vals}] -> Vals;
    []                        -> []
  end.

is_suspect_proc(#erl_top{pid = "!!!"}, _) ->
  false;
is_suspect_proc(Proc, {MaxMemory, MaxMqLen, MaxTotalHeapSize}) ->
  #erl_top{memory = Memory,
           message_queue_len = MessageQueueLen,
           total_heap_size = TotalHeapSize} =
    Proc,
  GreaterIfDef =
    fun ({undefined, _}) ->
          false;
        ({Comp, Value}) ->
          Value >= Comp
    end,
  ToCompare =
    [{MaxMemory, Memory}, {MaxMqLen, MessageQueueLen}, {MaxTotalHeapSize, TotalHeapSize}],
  lists:any(GreaterIfDef, ToCompare).

log_suspect_proc(Proc) ->
  ErlTopStr = system_monitor_lib:erl_top_to_str(Proc),
  Format = "Suspect Proc~n~s",
  ?LOG_WARNING(Format, [ErlTopStr], #{domain => [system_monitor]}).

-spec produce_fun_top(system_monitor_lib:ts()) -> ok.
produce_fun_top(TS) ->
  #{ current_function := CurrentFunctionTop
   , initial_call     := InitialCallTop
   } = get_function_top(),
  produce_fun_top(current_fun_top, CurrentFunctionTop, TS),
  produce_fun_top(initial_fun_top, InitialCallTop, TS),
  ok.

produce_fun_top(TopType, Values, TS) ->
  Node = node(),
  L = lists:map(fun({Function, PercentProcesses}) ->
                    {Node, TS, Function, PercentProcesses}
                end,
                Values),
  system_monitor_callback:produce(TopType, L).
