%%--------------------------------------------------------------------
%% Copyright 2022 k32
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
  snabbkaffe:fix_ct_logging(),
  application:load(?APP),
  application:set_env(?APP, vips, [some_random_name|vips()]),
  application:set_env(?APP, top_sample_interval, 1000),
  application:set_env(?APP, tick_interval, 100),
  application:set_env(?APP, top_significance_threshold,
                      #{ current_function => 0
                       , initial_call     => 0
                       , reductions       => 0
                       , abs_reductions   => 0
                       , memory           => 0
                       , num_processes    => 1
                       }),
  docker_cleanup(),
  ?assertMatch(0, docker_startup()),
  OldConf = application:get_all_env(?APP),
  [{old_conf, OldConf} | Config].

end_per_suite(_Config) ->
  docker_cleanup(),
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
       ?assertMatch([{App, N}|_] when is_atom(App) andalso is_number(N), system_monitor:get_app_top()),
       ?assertMatch([{App, N}|_] when is_atom(App) andalso is_number(N), system_monitor:get_abs_app_top()),
       ?assertMatch([{App, N}|_] when is_atom(App) andalso is_number(N), system_monitor:get_app_memory()),
       ?assertMatch([{App, N}|_] when is_atom(App) andalso is_number(N), system_monitor:get_app_processes()),
       ?assertMatch( #{ initial_call     := [{{M1, F1, A1}, V1}|_]
                      , current_function := [{{M2, F2, A2}, V2}|_]
                      } when is_atom(M1) andalso is_atom(M2) andalso is_atom(F1) andalso is_atom(F2) andalso
                             is_number(A1) andalso is_number(A2) andalso is_number(V1) andalso is_number(V2)
                   , system_monitor:get_function_top()
                   )
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
       Top = system_monitor:get_proc_top(),
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

t_add_remove_vips(_) ->
  ?check_trace(
     #{timetrap => 30000},
     try
       application:set_env(?APP, top_max_procs, 1),
       application:ensure_all_started(?APP),
       ?wait_async_action( begin
                             system_monitor:add_vip(global_name_server),
                             system_monitor:remove_vip(system_monitor)
                           end
                         , #{?snk_kind := sysmon_report_data}
                         ),
       Top = system_monitor:get_proc_top(),
       %% Check that "warning" process is there:
       ?assertMatch( #erl_top{pid = "!!!", group_leader = "!!!", registered_name = too_many_processes}
                   , lists:keyfind("!!!", #erl_top.pid, Top)
                   ),
       %% Check the VIPs:
       ?assertMatch(false, system_monitor:get_proc_info(system_monitor)),
       ?assertMatch(#erl_top{}, system_monitor:get_proc_info(application_controller)),
       ?assertMatch(#erl_top{}, system_monitor:get_proc_info(global_name_server))
     after
       application:stop(?APP)
     end,
     []).

t_postgres(_) ->
  ?check_trace(
     #{timetrap => 30000},
     try
       application:set_env(?APP, top_max_procs, 1),
       application:set_env(?APP, db_name, "postgres"),
       application:set_env(?APP, callback_mod, system_monitor_pg),
       application:ensure_all_started(?APP),
       link(whereis(system_monitor_pg)), % if it crashes we will know
       {ok, _} = ?block_until(#{?snk_kind := sysmon_produce, backend := pg, type := proc_top,
                                msg := Msg} when Msg#erl_top.registered_name =:= too_many_processes),
       {ok, _} = ?block_until(#{?snk_kind := sysmon_produce, backend := pg, type := proc_top,
                                msg := Msg} when Msg#erl_top.registered_name =:= system_monitor)
     after
       unlink(whereis(system_monitor_pg)),
       application:stop(?APP)
     end,
     [ fun ?MODULE:no_pg_query_failures/1
     , fun ?MODULE:success_proc_top_queries/1
     , fun ?MODULE:success_app_top_queries/1
     , fun ?MODULE:success_fun_top_queries/1
     , fun ?MODULE:success_node_status_queries/1
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
       ?block_until(#{?snk_kind := "Abnormal process count"}),
       %% Now insert a failing status check, to verify that it doesn't
       %% affect the others:
       FailingCheck = {?MODULE, failing_check, false, 1},
       application:set_env(?APP, status_checks, [FailingCheck|?CFG(status_checks)]),
       system_monitor:reset(),
       ?block_until(#{?snk_kind := sysmon_failing_check_run}, infinity, 0),
       ?block_until(#{?snk_kind := "Abnormal process count"}, infinity, 0)
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

no_pg_query_failures(Trace) ->
  ?assertMatch([], ?of_kind(system_monitor_pg_query_error, Trace)).

success_proc_top_queries(Trace) ->
  contains_type(proc_top, Trace).

success_app_top_queries(Trace) ->
  contains_type(app_top, Trace).

success_fun_top_queries(Trace) ->
  contains_type(initial_fun_top, Trace) andalso contains_type(current_fun_top, Trace).

success_node_status_queries(Trace) ->
  contains_type(node_status, Trace).

contains_type(Type, Trace) ->
  lists:search( ?match_event(#{?snk_kind := sysmon_produce, backend := pg, type := T}
                             when T =:= Type)
              , Trace
              ) =/= false.

check_produce_seal(Trace) ->
  ?assert(
     ?strict_causality( #{?snk_kind := sysmon_produce, type := node_status}
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

failing_check() ->
  ?tp(sysmon_failing_check_run, #{}),
  error(deliberate).

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

docker_startup() ->
  exec("docker run -d --name sysmondb -p 5432:5432 \\
 -e SYSMON_PASS=system_monitor_password \\
 -e GRAFANA_PASS=system_monitor_password \\
 -e POSTGRES_PASSWORD=system_monitor_password \\
 ghcr.io/k32/sysmon-postgres:1.0.0").

docker_cleanup() ->
  exec("docker kill sysmondb"),
  exec("docker rm -f sysmondb").

-spec exec(file:filename()) -> integer().
exec(CMD) ->
  Port = open_port( {spawn, CMD}
                  , [ exit_status
                    , binary
                    , stderr_to_stdout
                    , {line, 300}
                    ]
                  ),
  collect_port_output(Port).

-spec collect_port_output(port()) -> integer().
collect_port_output(Port) ->
  receive
    {Port, {data, {_, Data}}} ->
      io:format(user, "docker: ~s~n", [Data]),
      collect_port_output(Port);
    {Port, {exit_status, ExitStatus}} ->
      ExitStatus
  end.
