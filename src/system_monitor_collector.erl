%%--------------------------------------------------------------------------------
%% Copyright 2022 k32
%% Copyright 2020 Klarna Bank AB
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

%%% @doc Collect Erlang process statistics and push it to the
%%% configured destination
-module(system_monitor_collector).

-behaviour(gen_server).

-include_lib("system_monitor/include/system_monitor.hrl").

%% API
-export([start_link/0, get_app_top/0, get_abs_app_top/0,
         get_app_memory/0, get_app_processes/0,
         get_function_top/0, get_proc_top/0, get_proc_top/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([function_top/0]).

-define(SERVER, ?MODULE).

-define(TOP_APP_TAB,   sysmon_top_app_tab).
-define(TOP_INIT_CALL, sysmon_top_init_call).
-define(TOP_CURR_FUN,  sysmon_top_curr_fun).
-define(TAB_OPTS, [private, named_table, set, {keypos, 1}]).

%% Type and record definitions

-define(HIST(PID, REDS, MEM), {PID, REDS, MEM}).

-record(state,
        { timer                 :: timer:tref()
        , old_data         = [] :: [hist()]
        , last_ts               :: integer()
        , proc_top         = [] :: [#erl_top{}]
        , app_top          = [] :: [#app_top{}]
        , initial_call_top = [] :: function_top()
        , current_fun_top  = [] :: function_top()
        }).

-record(delta,
        { pid      :: pid()
        , reg_name :: atom()
        , reds     :: non_neg_integer()
        , dreds    :: number()
        , memory   :: non_neg_integer()
        , dmemory  :: number()
        , mql      :: non_neg_integer()
        }).

-record(top_acc,
        { is_vip             :: fun((atom()) -> boolean())
        , dt                 :: float()
        , hist_data          :: [hist()]
        , sample_probability :: float()
        %% Tops
        , vips               :: [#delta{}]
        , memory             :: system_monitor_top:top()
        , dmemory            :: system_monitor_top:top()
        , dreds              :: system_monitor_top:top()
        , mql                :: system_monitor_top:top()
        }).

-type hist() :: ?HIST(pid(), non_neg_integer(), non_neg_integer()).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Get Erlang process top
-spec get_proc_top() -> {integer(), [#erl_top{}]}.
get_proc_top() ->
  {ok, Data} = gen_server:call(?SERVER, get_proc_top, infinity),
  Data.

%% @doc Get Erlang process top info for one process
-spec get_proc_top(pid()) -> #erl_top{} | false.
get_proc_top(Pid) ->
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

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
  {ok, TRef} = timer:send_after(sample_interval(), collect_data),
  {ok, #state{ timer       = TRef
             , last_ts     = timestamp()
             }}.

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
  Data = #{ initial_call     => State#state.initial_call_top
          , current_function => State#state.current_fun_top
          },
  {reply, {ok, Data}, State};
handle_call(_Msg, _From, State) ->
  {reply, {error, bad_call}, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(collect_data, State0) ->
  init_tables(),
  T1 = timestamp(),
  NumProcesses = erlang:system_info(process_count),
  Pids = case NumProcesses < cfg(top_max_procs) of
           true  -> lists:sort(processes());
           false -> lists:sort(get_vip_pids())
         end,
  State1 = update_proc_top(State0, T1, Pids),
  State = finalize_aggr_top(State1, NumProcesses),
  T2 = timestamp(),
  SleepTime = max(500, sample_interval() - (T2 - T1)),
  {ok, TRef} = timer:send_after(SleepTime, collect_data),
  {noreply, State#state{ timer = TRef
                       }};
handle_info(_Info, State) ->
  {noreply, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% Very important processes
%%--------------------------------------------------------------------

-spec vip_names() -> [atom()].
vip_names() ->
  cfg(vips).

-spec get_vip_pids() -> [pid()].
get_vip_pids() ->
  lists:foldl( fun(I, Acc) ->
                   case whereis(I) of
                     undefined -> Acc;
                     Pid       -> [Pid|Acc]
                   end
               end
             , []
             , vip_names()
             ).

-spec make_vip_pred() -> fun((atom()) -> boolean()).
make_vip_pred() ->
  Map = maps:from_list([{I, []} || I <- vip_names()]),
  fun(Name) -> maps:is_key(Name, Map) end.

%%--------------------------------------------------------------------
%% Proc top collection
%%--------------------------------------------------------------------

-spec update_proc_top(#state{}, integer(), [pid()]) -> #state{}.
update_proc_top(State = #state{old_data = OldData, last_ts = LastTs}, Now, Pids) ->
  Dt = max(1, Now - LastTs),
  {Deltas, NewData} = top_deltas(OldData, Pids, Dt),
  State#state{ old_data = NewData
             , proc_top = [enrich(I, Now) || I <- Deltas]
             }.

-spec top_deltas([hist()], [pid()], float()) -> {[#delta{}], [hist()]}.
top_deltas(OldData, Pids, Dt) ->
  Acc = go(OldData, Pids, empty_top(length(Pids), Dt)),
  {top_to_list(Acc), Acc#top_acc.hist_data}.

-spec go([hist()], [pid()], #top_acc{}) -> #top_acc{}.
go([], [], Acc) ->
  Acc;
go(_Old, [], Acc) ->
  %% The rest of the processes have terminated, discard them:
  Acc;
go([?HIST(OldPid, _, _)|OldL], PidL = [Pid|_], Acc) when Pid > OldPid ->
  %% OldPid terminated, discard it:
  go(OldL, PidL, Acc);
go([Old = ?HIST(Pid, _, _)|OldL], [Pid|PidL], Acc0) ->
  %% This is a process that we've seen before:
  Acc = update_acc(Old, Acc0),
  go(OldL, PidL, Acc);
go(OldL, [Pid|PidL], Acc0) ->
  %% This is a new process:
  Acc = update_acc(?HIST(Pid, 0, 0), Acc0),
  go(OldL, PidL, Acc).

-spec update_acc(hist(), #top_acc{}) -> #top_acc{}.
update_acc( ?HIST(Pid, OldReds, OldMem)
          , #top_acc{ dt        = Dt
                    , hist_data = Histories
                    } = Acc0
          ) ->
  case get_pid_info(Pid) of
    {RegName, Reds, Mem, MQL} ->
      DReds = (Reds - OldReds) / Dt,
      DMem = (Mem  - OldMem) / Dt,
      Delta = #delta{ reg_name = RegName
                    , pid      = Pid
                    , reds     = Reds
                    , dreds    = DReds
                    , memory   = Mem
                    , dmemory  = DMem
                    , mql      = MQL
                    },
      Acc = maybe_push_to_top(Acc0, Delta),
      diceroll(Acc#top_acc.sample_probability) andalso
        maybe_update_aggr_top(Delta),
      Acc#top_acc{ hist_data = [?HIST(Pid, Reds, Mem) | Histories]
                 };
    undefined ->
      Acc0
  end.

%%--------------------------------------------------------------------
%% Sample top stuff
%%--------------------------------------------------------------------

-spec maybe_update_aggr_top(#delta{}) -> ok.
maybe_update_aggr_top(#delta{ pid    = Pid
                            , dreds  = DReds
                            , memory = Memory
                            }) ->
  case erlang:process_info(Pid, [current_function, group_leader, initial_call, dictionary]) of
    undefined ->
      ok;
    [{current_function, CurrentFunction}, {group_leader, GL}|L] ->
      InitialCall = initial_call(L),
      App = application_controller:get_application(GL),
      ets:update_counter(?TOP_CURR_FUN, CurrentFunction, {2, 1}, {CurrentFunction, 0}),
      ets:update_counter(?TOP_INIT_CALL, InitialCall, {2, 1}, {InitialCall, 0}),
      ets:update_counter(?TOP_APP_TAB, App, [{2, 1}, {3, round(DReds)}, {4, Memory}], {App, 0, 0, 0}),
      ok
  end.

-spec init_tables() -> ok.
init_tables() ->
  ets:new(?TOP_APP_TAB, ?TAB_OPTS),
  ets:new(?TOP_CURR_FUN, ?TAB_OPTS),
  ets:new(?TOP_INIT_CALL, ?TAB_OPTS).

-spec finalize_aggr_top(#state{}, non_neg_integer()) -> #state{}.
finalize_aggr_top(State, NProc) ->
  #{ current_function := CurrFunThreshold
   , initial_call     := InitialCallThreshold
   , reductions       := ReductionsThreshold
   , memory           := MemThreshold
   , num_processes    := NProcCutoff
   } = cfg(top_significance_threshold),
  %% Collect data:
  SampleSize = top_sample_size(),
  CurrFunTop = filter_nproc_results(?TOP_CURR_FUN, CurrFunThreshold, NProc, SampleSize),
  InitCallTop = filter_nproc_results(?TOP_INIT_CALL, InitialCallThreshold, NProc, SampleSize),
  AppTop = filter_app_top(NProcCutoff, ReductionsThreshold, MemThreshold),
  %% Cleanup:
  ets:delete(?TOP_APP_TAB),
  ets:delete(?TOP_CURR_FUN),
  ets:delete(?TOP_INIT_CALL),
  State#state{ app_top          = AppTop
             , initial_call_top = InitCallTop
             , current_fun_top  = CurrFunTop
             }.

filter_app_top(NProcCutoff, ReductionsThreshold, MemThreshold) ->
  L = ets:tab2list(?TOP_APP_TAB),
  {TotalReds, TotalMem} = lists:foldl( fun({_, _, Reds, Mem}, {R, M}) ->
                                           {Reds + R, Mem + M}
                                       end
                                     , {0, 0}
                                     , L
                                     ),
  Factor = 1 / max(1, TotalReds),
  RedCutoff = ReductionsThreshold * TotalReds,
  MemCutoff = MemThreshold * TotalMem,
  [#app_top{ app       = App
           , red_abs   = Reds
           , red_rel   = Reds * Factor
           , memory    = Mem
           , processes = Procs
           }
   || {App, Procs, Reds, Mem} <- L,
      Reds > RedCutoff orelse Mem > MemCutoff orelse Procs > NProcCutoff].

filter_nproc_results(Tab, Threshold, NProc, SampleSize) ->
  Cutoff = Threshold * SampleSize,
  Factor = 1 / min(NProc, SampleSize),
  [{K, V * Factor} || {K, V} <- ets:tab2list(Tab), V > Cutoff].

%%--------------------------------------------------------------------
%% Top accumulator manipulation
%%--------------------------------------------------------------------

-spec empty_top(non_neg_integer(), float()) -> #top_acc{}.
empty_top(NProc, Dt) ->
  Empty = system_monitor_top:empty(cfg(top_num_items)),
  SampleProbability = NProc / top_sample_size(),
  #top_acc{ is_vip             = make_vip_pred()
          , dt                 = Dt
          , hist_data          = []
          , sample_probability = SampleProbability
          , vips               = []
          , memory             = Empty
          , dmemory            = Empty
          , dreds              = Empty
          , mql                = Empty
          }.

-spec maybe_push_to_top(#top_acc{}, #delta{}) -> #top_acc{}.
maybe_push_to_top(#top_acc{ is_vip             = IsVip
                          , vips               = GVIPs
                          , memory             = GMem
                          , dreds              = GDReds
                          , dmemory            = GDMem
                          , mql                = GMQL
                          } = Acc,
                  Delta) ->
  Acc#top_acc{ vips    = [Delta || IsVip(Delta#delta.reg_name)] ++ GVIPs
             , memory  = system_monitor_top:push(#delta.memory,  Delta, GMem)
             , dmemory = system_monitor_top:push(#delta.dmemory, Delta, GDMem)
             , dreds   = system_monitor_top:push(#delta.dreds,   Delta, GDReds)
             , mql     = system_monitor_top:push(#delta.mql,     Delta, GMQL)
             }.

-spec top_to_list(#top_acc{}) -> [#delta{}].
top_to_list(#top_acc{ vips    = VIPs
                    , memory  = GMem
                    , dreds   = GDReds
                    , dmemory = GDMem
                    , mql     = GMQL
                    }) ->
  lists:usort(VIPs ++ lists:flatmap( fun system_monitor_top:to_list/1
                                   , [GMem, GDReds, GDMem, GMQL]
                                   )).

%%--------------------------------------------------------------------
%% Getting process info
%%--------------------------------------------------------------------

-spec enrich(#delta{}, integer()) -> #erl_top{}.
enrich(#delta{ pid      = Pid
             , reg_name = RegName
             , reds     = Reds
             , dreds    = DReds
             , memory   = Memory
             , dmemory  = DMem
             , mql      = MQL
             }, Now) ->
  Info = process_info(Pid, [group_leader, initial_call, dictionary, stack_size,
                            heap_size, total_heap_size, current_function,
                            current_stacktrace]),
  case Info of
    [{group_leader, GL}, {initial_call, _}, {dictionary, _},
     {stack_size, StackSize}, {heap_size, HeapSize}, {total_heap_size, Total},
     {current_function, CurrentFunction}, {current_stacktrace, CurrentStack}] ->
      InitialCall = initial_call(Info);
    undefined ->
      GL = "<?.?.?>",
      InitialCall = {'?', '?', 0},
      StackSize = 0,
      HeapSize = 0,
      Total = 0,
      CurrentStack = [],
      CurrentFunction = undefined
  end,
  #erl_top{ node               = node()
          , ts                 = Now
          , pid                = pid_to_list(Pid)
          , group_leader       = GL
          , dreductions        = DReds
          , dmemory            = DMem
          , reductions         = Reds
          , memory             = Memory
          , message_queue_len  = MQL
          , initial_call       = InitialCall
          , registered_name    = RegName
          , stack_size         = StackSize
          , heap_size          = HeapSize
          , total_heap_size    = Total
          , current_stacktrace = CurrentStack
          , current_function   = CurrentFunction
          }.

-spec get_pid_info(pid()) -> {RegName, Reds, Mem, MQL} | undefined
          when RegName :: atom(),
               Reds    :: non_neg_integer(),
               Mem     :: non_neg_integer(),
               MQL     :: non_neg_integer().
get_pid_info(Pid) ->
  case erlang:process_info(Pid, [registered_name, reductions, memory, message_queue_len]) of
    [ {registered_name,   RegName}
    , {reductions,        Reds}
    , {memory,            Mem}
    , {message_queue_len, MQL}
    ] ->
      {RegName, Reds, Mem, MQL};
    undefined ->
      undefined
  end.

-spec initial_call(proplists:proplist()) -> mfa().
initial_call(Info)  ->
  case proplists:get_value(initial_call, Info) of
    {proc_lib, init_p, 5} ->
      proc_lib:translate_initial_call(Info);
    ICall ->
      ICall
  end.

%%--------------------------------------------------------------------
%% Misc
%%--------------------------------------------------------------------

cfg(Key) ->
  {ok, Val} = application:get_env(?APP, Key),
  Val.

timestamp() ->
  erlang:monotonic_time(microsecond).

sample_interval() ->
  cfg(top_sample_interval).

top_sample_size() ->
  cfg(top_sample_size).

diceroll(Probability) ->
  rand:uniform() < Probability.

-spec do_get_app_top(integer()) -> [{atom(), number()}].
do_get_app_top(FieldId) ->
  {ok, Data} = gen_server:call(?SERVER, get_app_top, infinity),
  lists:reverse(
    lists:keysort(2, [{Val#app_top.app, element(FieldId, Val)}
                      || Val <- Data])).

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
