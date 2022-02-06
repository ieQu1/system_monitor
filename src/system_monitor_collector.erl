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

-include("sysmon_int.hrl").

%% API
-export([start_link/0, timestamp/0, add_vip/1, remove_vip/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).

-define(TOP_APP_TAB,   sysmon_top_app_tab).
-define(TOP_INIT_CALL, sysmon_top_init_call).
-define(TOP_CURR_FUN,  sysmon_top_curr_fun).
-define(TAB_OPTS,      [private, named_table, set, {keypos, 1}]).

-define(COUNT, diceroll_counter).

%% Type and record definitions

-define(HIST(PID, REDS, MEM), {PID, REDS, MEM}).

-record(state,
        { timer                :: timer:tref()
        , old_data        = [] :: [hist()]
        , last_ts              :: integer()
        , time_to_collect = 0  :: non_neg_integer()
        }).

-record(delta,
        { pid      :: pid()
        , reg_name :: atom()
        , reds     :: non_neg_integer()
        , dreds    :: non_neg_integer()
        , memory   :: non_neg_integer()
        , dmemory  :: non_neg_integer()
        , mql      :: non_neg_integer()
        }).

-record(top_acc,
        { is_vip        :: #{atom() => _}
        , dt            :: non_neg_integer()
        , hist_data     :: [hist()]
        , sample_modulo :: non_neg_integer()
        %% Tops
        , vips          :: [#delta{}]
        , memory        :: system_monitor_top:top()
        , dmemory       :: system_monitor_top:top()
        , dreds         :: system_monitor_top:top()
        , mql           :: system_monitor_top:top()
        }).

-type hist() :: ?HIST(pid(), non_neg_integer(), non_neg_integer()).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Add a VIP
-spec add_vip(atom() | [atom()]) -> ok.
add_vip(RegName) when is_atom(RegName) ->
  add_vip([RegName]);
add_vip(RegNames) when is_list(RegNames) ->
  gen_server:call(?SERVER, {add_vip, RegNames}).

%% @doc Add a VIP
-spec remove_vip(atom()) -> ok.
remove_vip(RegName) ->
  gen_server:call(?SERVER, {remove_vip, RegName}).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

timestamp() ->
  erlang:system_time(microsecond).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
  put(?COUNT, 0),
  {ok, TRef} = timer:send_after(sample_interval(), collect_data),
  {ok, #state{ timer       = TRef
             , last_ts     = timestamp()
             }}.

handle_call({add_vip, RegNames}, _From, State) ->
  application:set_env(?APP, vips, lists:usort(RegNames ++ ?CFG(vips))),
  {reply, ok, State};
handle_call({remove_vip, RegName}, _From, State) ->
  application:set_env(?APP, vips, lists:delete(RegName, ?CFG(vips))),
  {reply, ok, State};
handle_call(_Msg, _From, State) ->
  {reply, {error, bad_call}, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(collect_data, State0) ->
  init_tables(),
  T1 = timestamp(),
  NumProcesses = erlang:system_info(process_count),
  TooManyPids = NumProcesses > ?CFG(top_max_procs),
  Pids = case TooManyPids of
           false -> lists:sort(processes());
           true  -> lists:sort(get_vip_pids())
         end,
  {ProcTop, State} = collect_proc_top(State0, T1, Pids, TooManyPids),
  {AppTop, InitCallTop, CurrFunTop} = finalize_aggr_top(NumProcesses),
  %% Report the collected data:
  system_monitor:report_data(T1, {ProcTop, AppTop, InitCallTop, CurrFunTop}),
  %% Prepare for the next iteration:
  T2 = timestamp(),
  LastRunTime = T2 - T1,
  SleepTime = max(500, sample_interval() - LastRunTime),
  erlang:garbage_collect(self()),
  {ok, TRef} = timer:send_after(SleepTime, collect_data),
  {noreply, State#state{ timer           = TRef
                       , time_to_collect = LastRunTime
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
  ?CFG(vips).

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

-spec make_is_vip() -> #{atom() => []}.
make_is_vip() ->
  maps:from_list([{I, []} || I <- vip_names()]).

%%--------------------------------------------------------------------
%% Proc top collection
%%--------------------------------------------------------------------

-spec collect_proc_top(#state{}, integer(), [pid()], boolean()) -> {[#erl_top{}], #state{}}.
collect_proc_top(State = #state{old_data = OldData, last_ts = LastTs}, Now, Pids, TooManyPids) ->
  Dt = max(1, Now - LastTs),
  {Deltas, NewData} = top_deltas(OldData, Pids, Dt),
  ProcTop = [make_fake_proc(Now) || TooManyPids] ++ [enrich(I, Now) || I <- Deltas],
  {ProcTop, State#state{old_data = NewData}}.

-spec top_deltas([hist()], [pid()], non_neg_integer()) -> {[#delta{}], [hist()]}.
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
      DReds = (Reds - OldReds) div Dt,
      DMem = (Mem  - OldMem) div Dt,
      Delta = #delta{ reg_name = RegName
                    , pid      = Pid
                    , reds     = Reds
                    , dreds    = DReds
                    , memory   = Mem
                    , dmemory  = DMem
                    , mql      = MQL
                    },
      Acc = maybe_push_to_top(Acc0, Delta),
      diceroll(Acc#top_acc.sample_modulo) andalso
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
      App = case application_controller:get_application(GL) of
              {ok, A}   -> A;
              undefined -> undefined
            end,
      ets:update_counter(?TOP_CURR_FUN, CurrentFunction, {2, 1}, {CurrentFunction, 0}),
      ets:update_counter(?TOP_INIT_CALL, InitialCall, {2, 1}, {InitialCall, 0}),
      ets:update_counter(?TOP_APP_TAB, App, [{2, 1}, {3, DReds}, {4, Memory}], {App, 0, 0, 0}),
      ok
  end.

-spec init_tables() -> ok.
init_tables() ->
  ets:new(?TOP_APP_TAB, ?TAB_OPTS),
  ets:new(?TOP_CURR_FUN, ?TAB_OPTS),
  ets:new(?TOP_INIT_CALL, ?TAB_OPTS).

-spec finalize_aggr_top(non_neg_integer()) ->
        {[#app_top{}], system_monitor:function_top(), system_monitor:function_top()}.
finalize_aggr_top(NProc) ->
  %% Collect data:
  SampleSize = top_sample_size(),
  CurrFunTop = filter_nproc_results(?TOP_CURR_FUN, NProc, SampleSize),
  InitCallTop = filter_nproc_results(?TOP_INIT_CALL, NProc, SampleSize),
  AppTop = filter_app_top(),
  %% Cleanup:
  ets:delete(?TOP_APP_TAB),
  ets:delete(?TOP_CURR_FUN),
  ets:delete(?TOP_INIT_CALL),
  {AppTop, InitCallTop, CurrFunTop}.

filter_app_top() ->
  L = ets:tab2list(?TOP_APP_TAB),
  TotalReds = lists:foldl( fun({_, _, Reds, _Mem}, Acc) ->
                               Reds + Acc
                           end
                         , 0
                         , L
                         ),
  Factor = 1 / max(1, TotalReds),
  [#app_top{ app       = App
           , red_abs   = Reds
           , red_rel   = Reds * Factor
           , memory    = Mem
           , processes = Procs
           }
   || {App, Procs, Reds, Mem} <- L].

filter_nproc_results(Tab, NProc, SampleSize) ->
  Factor = 1 / min(NProc, SampleSize),
  [{K, V * Factor} || {K, V} <- ets:tab2list(Tab)].

%%--------------------------------------------------------------------
%% Top accumulator manipulation
%%--------------------------------------------------------------------

-spec empty_top(non_neg_integer(), non_neg_integer()) -> #top_acc{}.
empty_top(NProc, Dt) ->
  Empty = system_monitor_top:empty(?CFG(top_num_items)),
  SampleModulo = max(1, NProc div top_sample_size()),
  #top_acc{ is_vip         = make_is_vip()
          , dt             = Dt
          , hist_data      = []
          , sample_modulo  = SampleModulo
          , vips           = []
          , memory         = Empty
          , dmemory        = Empty
          , dreds          = Empty
          , mql            = Empty
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
  Acc#top_acc{ vips    = [Delta || maps:is_key(Delta#delta.reg_name, IsVip)] ++ GVIPs
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
          , group_leader       = ensure_list(GL)
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

make_fake_proc(Now) ->
  Infinity = 99999999999,
  #erl_top{ node               = node()
          , ts                 = Now
          , pid                = "!!!"
          , group_leader       = "!!!"
          , dreductions        = Infinity
          , dmemory            = Infinity
          , reductions         = Infinity
          , memory             = Infinity
          , message_queue_len  = Infinity
          , initial_call       = {undefined, undefined, 0}
          , registered_name    = too_many_processes
          , stack_size         = Infinity
          , heap_size          = Infinity
          , total_heap_size    = Infinity
          , current_stacktrace = []
          , current_function   = {undefined, undefined, 0}
          }.

sample_interval() ->
  ?CFG(top_sample_interval).

top_sample_size() ->
  ?CFG(top_sample_size).

diceroll(Mod) ->
  Cnt = get(?COUNT) + 1,
  put(?COUNT, Cnt rem Mod) =:= 0.

ensure_list(Pid) when is_pid(Pid) ->
  pid_to_list(Pid);
ensure_list(Str) ->
  Str.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
