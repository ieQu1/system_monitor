%%--------------------------------------------------------------------
%% Copyright (c) 2022 k32. All Rights Reserved.
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
%%--------------------------------------------------------------------
-module(system_monitor_scheduler).

%% API:
-export([ start_link/0
        ]).

-export([ report_full_status/0
        , check_process_count/0
        , suspect_procs/0
        , erl_top_to_str/1
        , fmt_mfa/1
        , fmt_stack/1
        ]).

%% behavior callbacks:
-export([]).

%% internal exports:
-export([]).

-export_type([]).

%%================================================================================
%% Type declarations
%%================================================================================

%%================================================================================
%% API funcions
%%================================================================================

%%================================================================================
%% behavior callbacks
%%================================================================================

%%================================================================================
%% Internal exports
%%================================================================================


%% @doc Check the number of processes and log an aggregate summary of
%% the process info if the count is above Threshold.
-spec check_process_count() -> ok.
check_process_count() ->
  {ok, MaxProcs} = application:get_env(?APP, top_max_procs),
  case erlang:system_info(process_count) of
    Count when Count > MaxProcs div 5 ->
      ?LOG_WARNING( "Abnormal process count (~p).~n"
                  , [Count]
                  , #{domain => [system_monitor]}
                  );
    _ -> ok
  end.

suspect_procs() ->
  {_TS, ProcTop} = get_proc_top(),
  Env = fun(Name) -> application:get_env(?APP, Name, undefined) end,
  Conf =
    {Env(suspect_procs_max_memory),
     Env(suspect_procs_max_message_queue_len),
     Env(suspect_procs_max_total_heap_size)},
  SuspectProcs = lists:filter(fun(Proc) -> is_suspect_proc(Proc, Conf) end, ProcTop),
  lists:foreach(fun log_suspect_proc/1, SuspectProcs).

%%================================================================================
%% Internal functions
%%================================================================================

%%------------------------------------------------------------------------------
%% Monitor for processes with suspect stats
%%------------------------------------------------------------------------------

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
  ErlTopStr = erl_top_to_str(Proc),
  Format = "Suspect Proc~n~s",
  ?LOG_WARNING(Format, [ErlTopStr], #{domain => [system_monitor]}).

%% @doc Report top processes
-spec report_full_status() -> ok.
report_full_status() ->
  %% `TS' variable should be used consistently in all following
  %% reports for this time interval, so it can be used as a key to
  %% lookup the relevant events
  {TS, ProcTop} = system_monitor_collector:get_proc_top(),
  system_monitor_callback:produce(proc_top, ProcTop),
  report_app_top(TS),
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
  system_monitor_callback:produce(node_role,
                                  [{node_role, node(), TS, iolist_to_binary(NodeReport)}]).

%% @doc Calculate reductions per application.
-spec report_app_top(integer()) -> ok.
report_app_top(TS) ->
  AppReds  = system_monitor:get_abs_app_top(),
  present_results(app_top, reductions, AppReds, TS),
  AppMem   = system_monitor:get_app_memory(),
  present_results(app_top, memory, AppMem, TS),
  AppProcs = system_monitor:get_app_processes(),
  present_results(app_top, processes, AppProcs, TS),
  #{ current_function := CurrentFunction
   , initial_call := InitialCall
   } = system_monitor:get_function_top(),
  present_results(fun_top, current_function, CurrentFunction, TS),
  present_results(fun_top, initial_call, InitialCall, TS),
  ok.

%%--------------------------------------------------------------------
%% @doc Push app_top or fun_top information to the configured destination
%%--------------------------------------------------------------------
present_results(Record, Tag, Values, TS) ->
  {ok, Thresholds} = application:get_env(?APP, top_significance_threshold),
  Threshold = maps:get(Tag, Thresholds, 0),
  Node = node(),
  L = lists:filtermap(fun ({Key, Val}) when Val > Threshold ->
                            {true, {Record, Node, TS, Key, Tag, Val}};
                          (_) ->
                            false
                      end,
                      Values),
  system_monitor_callback:produce(Record, L).

%%--------------------------------------------------------------------
%% @doc logs "the interesting parts" of erl_top
%%--------------------------------------------------------------------
erl_top_to_str(Proc) ->
  #erl_top{registered_name = RegisteredName,
           pid = Pid,
           initial_call = InitialCall,
           memory = Memory,
           message_queue_len = MessageQueueLength,
           stack_size = StackSize,
           heap_size = HeapSize,
           total_heap_size = TotalHeapSize,
           current_function = CurrentFunction,
           current_stacktrace = CurrentStack} =
    Proc,
  WordSize = erlang:system_info(wordsize),
  Format =
    "registered_name=~p~n"
    "offending_pid=~s~n"
    "initial_call=~s~n"
    "memory=~p (~s)~n"
    "message_queue_len=~p~n"
    "stack_size=~p~n"
    "heap_size=~p (~s)~n"
    "total_heap_size=~p (~s)~n"
    "current_function=~s~n"
    "current_stack:~n~s",
  Args =
    [RegisteredName,
     Pid,
     fmt_mfa(InitialCall),
     Memory, fmt_mem(Memory),
     MessageQueueLength,
     StackSize,
     HeapSize, fmt_mem(WordSize * HeapSize),
     TotalHeapSize, fmt_mem(WordSize * TotalHeapSize),
     fmt_mfa(CurrentFunction),
     fmt_stack(CurrentStack)],
  io_lib:format(Format, Args).

fmt_mem(Mem) ->
  Units = [{1, "Bytes"}, {1024, "KB"}, {1024 * 1024, "MB"}, {1024 * 1024 * 1024, "GB"}],
  MemIsSmallEnough = fun({Dividor, _UnitStr}) -> Mem =< Dividor * 1024 end,
  {Dividor, UnitStr} =
    find_first(MemIsSmallEnough, Units, {1024 * 1024 * 1024 * 1024, "TB"}),
  io_lib:format("~.1f ~s", [Mem / Dividor, UnitStr]).

fmt_stack(CurrentStack) ->
  [[fmt_mfa(MFA), "\n"] || MFA <- CurrentStack].

fmt_mfa({Mod, Fun, Arity, Prop}) ->
  case proplists:get_value(line, Prop, undefined) of
    undefined ->
      fmt_mfa({Mod, Fun, Arity});
    Line ->
      io_lib:format("~s:~s/~p (Line ~p)", [Mod, Fun, Arity, Line])
  end;
fmt_mfa({Mod, Fun, Arity}) ->
  io_lib:format("~s:~s/~p", [Mod, Fun, Arity]);
fmt_mfa(L) ->
  io_lib:format("~p", [L]).

-spec find_first(fun((any()) -> boolean()), [T], Default) -> T | Default.
find_first(Pred, List, Default) ->
  case lists:search(Pred, List) of
    {value, Elem} -> Elem;
    false -> Default
  end.
