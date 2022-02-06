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
  application:load(?APP),
  application:set_env(?APP, vips, [some_random_name|vips()]),
  application:set_env(?APP, top_sample_interval, 1000),
  application:set_env(?APP, tick_interval, 100),
  OldConf = application:get_all_env(?APP),
  [{old_conf, OldConf} | Config].

end_per_suite(_Config) ->
  ok.

init_per_testcase(TestCase, Config) ->
  logger:notice(asciiart:visible($%, "Starting ~p", [TestCase])),
  Config.

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
       [?block_until(#{?snk_kind := sysmon_report_data}, infinity, 0) || _ <- lists:seq(1, 10)],
       ?assertMatch([{_, _}|_], system_monitor:get_app_top()),
       ?assertMatch([{_, _}|_], system_monitor:get_abs_app_top()),
       ?assertMatch([{_, _}|_], system_monitor:get_app_memory()),
       ?assertMatch([{_, _}|_], system_monitor:get_app_processes())
     after
       application:stop(?APP)
     end,
     [ fun ?MODULE:check_produce_seal/1
     , fun ?MODULE:check_produce_vips/1
     ]).

t_too_many_procs(_) ->
  ?check_trace(
     #{timetrap => 30000},
     try
       application:set_env(?APP, top_max_procs, 1),
       application:ensure_all_started(?APP),
       ?block_until(#{?snk_kind := sysmon_report_data}),
       {_TS, Top} = system_monitor:get_proc_top(),
       %% Check that "warning" process is there:
       ?assertMatch( #erl_top{pid = "!!!", group_leader = "!!!", registered_name = too_many_processes}
                   , lists:keyfind("!!!", #erl_top.pid, Top)
                   ),
       %% Check that the VIPs are still there:
       ?assertMatch(#erl_top{}, system_monitor:get_proc_info(system_monitor_collector)),
       ?assertMatch(#erl_top{}, system_monitor:get_proc_info(system_monitor)),
       ?assertMatch(#erl_top{}, system_monitor:get_proc_info(application_controller)),
       %% Misc checks:
       ?assertMatch(false, system_monitor:get_proc_info(some_random_name))
     after
       application:stop(?APP)
     end,
     [ fun ?MODULE:check_produce_seal/1
     , fun ?MODULE:check_produce_vips/1
     ]).

t_builtin_checks(_) ->
  ?check_trace(
     #{timetrap => 30000},
     try
       NProc = erlang:system_info(process_count),
       application:set_env(?APP, suspect_procs_max_memory, 1),
       application:set_env(?APP, top_max_procs, NProc * 2),
       application:set_env(?APP, node_status_fun, {?MODULE, node_status}),
       application:ensure_all_started(?APP),
       ?block_until(#{?snk_kind := "Abnormal process count"})
     after
       application:stop(?APP)
     end,
     []).

t_events(_) ->
  ?check_trace(
     try
       application:ensure_all_started(?APP),
       ?block_until(#{?snk_kind := sysmon_report_data}),
       GCInfo = [{timeout, 100}, {heap_size, 42}, {heap_block_size}, {stack_size},
                 {mbuf_size, 42}, {old_heap_size, 42}, {old_heap_block_size, 42}],
       ?wait_async_action( system_monitor_events ! {monitor, whereis(system_monitor), long_gc, GCInfo}
                         , #{?snk_kind := "system monitor event", type := long_gc}
                         ),
       ?wait_async_action( system_monitor_events ! {monitor, list_to_pid("<0.42.42>"), long_gc, GCInfo}
                         , #{?snk_kind := "system monitor event", type := long_gc}
                         ),
       PortInfo = [{timeout, 42}, {port_op, timeout}],
       ?wait_async_action( system_monitor_events ! {monitor, hd(erlang:ports()), long_schedule, PortInfo}
                         , #{?snk_kind := "system monitor event", type := long_schedule}
                         )
     after
       application:stop(?APP)
     end,
     []).

%%================================================================================
%% Trace specs
%%================================================================================

check_produce_seal(Trace) ->
  ?assert(
     ?strict_causality( #{?snk_kind := sysmon_produce, type := node_role}
                      , #{?snk_kind := sysmon_report_data}
                      , Trace
                      )).

check_produce_vips(Trace) ->
  [?assert(
      ?strict_causality( #{?snk_kind := sysmon_produce, type := proc_top, msg := Msg}
                              when Msg#erl_top.registered_name =:= VIP
                       , #{?snk_kind := sysmon_report_data}
                       , Trace
                       )) || VIP <- vips()],
  ok.

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

vips() ->
  [system_monitor, system_monitor_collector, application_controller].

node_status() ->
  "<b>this is my status</b>".
