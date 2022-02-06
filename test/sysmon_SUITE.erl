%%--------------------------------------------------------------------
%% Copyright (c) k32, Ltd. All Rights Reserved.
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
-module(sysmon_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include("sysmon_int.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").
-include_lib("stdlib/include/assert.hrl").

%%================================================================================
%% behavior callbacks
%%================================================================================

all() ->
  [Fun || {Fun, 1} <- ?MODULE:module_info(exports), lists:prefix("t_", atom_to_list(Fun))].

init_per_suite(Config) ->
  application:set_env(?APP, vips, [system_monitor_collector, system_monitor, some_random_name]),
  application:set_env(?APP, top_sample_interval, 1000),
  Config.

end_per_suite(_Config) ->
  ok.

init_per_testcase(TestCase, Config) ->
  logger:notice(asciiart:visible($%, "Starting ~p", [TestCase])),
  OldConf = application:get_all_env(?APP),
  [{old_conf, OldConf} | Config].

end_per_testcase(TestCase, Config) ->
  logger:notice(asciiart:visible($%, "Complete ~p", [TestCase])),
  snabbkaffe:stop(),
  [application:set_env(?APP, K, V) || {K, V} <- proplists:get_value(old_conf, Config)],
  Config.

%%================================================================================
%% Tests
%%================================================================================

t_start(_) ->
  ?check_trace(
     #{timetrap => 30000},
     try
       application:ensure_all_started(?APP),
       spawn_procs(100, 1000, 10000),
       %% Wait several events:
       [?block_until(#{?snk_kind := sysmon_report_data}, infinity, 0) || _ <- lists:seq(1, 10)]
     after
       application:stop(?APP)
     end,
     [fun check_dummy_callback/1]).

t_too_many_procs(_) ->
  ?check_trace(
     #{timetrap => 30000},
     try
       application:set_env(?APP, top_max_procs, 1),
       application:ensure_all_started(?APP),
       ?block_until(#{?snk_kind := sysmon_report_data}, infinity, 0),
       {_TS, Top} = system_monitor:get_proc_top(),
       %% Check that "warning" process is there:
       ?assertMatch( #erl_top{pid = "!!!", group_leader = "!!!", registered_name = too_many_processes}
                   , lists:keyfind("!!!", #erl_top.pid, Top)
                   ),
       %% Check that the VIPs are still there:
       ?assertMatch( #erl_top{}
                   , lists:keyfind(system_monitor_collector, #erl_top.registered_name, Top)
                   ),
       ?assertMatch( #erl_top{}
                   , lists:keyfind(system_monitor, #erl_top.registered_name, Top)
                   )
     after
       application:stop(?APP)
     end,
     [ fun check_dummy_callback/1
     ]).


%%================================================================================
%% Trace specs
%%================================================================================

check_dummy_callback(Trace) ->
  ?assert(
     ?strict_causality( #{?snk_kind := sysmon_dummy_produce, type := node_role}
                      , #{?snk_kind := sysmon_report_data}
                      , Trace
                      )).

%%================================================================================
%% Internal functions
%%================================================================================

spawn_procs(N, MinSleep, MaxSleep) ->
  Parent = self(),
  lists:foreach( fun(_) ->
                     erlang:spawn(?MODULE, idle_loop, [Parent, MinSleep, MaxSleep])
                 end
               , lists:seq(1, N)
               ).

idle_loop(Parent, MinSleep, MaxSleep) ->
  timer:sleep(MinSleep + rand:uniform(MaxSleep - MinSleep)),
  erlang:spawn(?MODULE, ?FUNCTION_NAME, [Parent, MinSleep, MaxSleep]).
