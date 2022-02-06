%%--------------------------------------------------------------------
%% Copyright (c) 2022 k32, Ltd. All Rights Reserved.
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
-module(system_monitor_lib).

%% @doc Utility functions

%% API:
-export([ cfg/1
        , fmt_mem/1
        , fmt_stack/1
        , fmt_mfa/1
        , find_first/3
        , erl_top_to_str/1
        , timestamp/0
        ]).

-export_type([ts/0]).

-include("sysmon_int.hrl").

%%================================================================================
%% Type declarations
%%================================================================================

-type ts() :: integer().

%%================================================================================
%% API funcions
%%================================================================================

%% @private
-spec cfg(atom()) -> _.
cfg(Key) ->
  {ok, Val} = application:get_env(?APP, Key),
  Val.

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

%% @doc logs "the interesting parts" of erl_top
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
     system_monitor_lib:fmt_mfa(InitialCall),
     Memory, system_monitor_lib:fmt_mem(Memory),
     MessageQueueLength,
     StackSize,
     HeapSize, system_monitor_lib:fmt_mem(WordSize * HeapSize),
     TotalHeapSize, system_monitor_lib:fmt_mem(WordSize * TotalHeapSize),
     system_monitor_lib:fmt_mfa(CurrentFunction),
     system_monitor_lib:fmt_stack(CurrentStack)],
  io_lib:format(Format, Args).

-spec timestamp() -> ts().
timestamp() ->
  erlang:system_time(microsecond).

%%================================================================================
%% Internal functions
%%================================================================================
