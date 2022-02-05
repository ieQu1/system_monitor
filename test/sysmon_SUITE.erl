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

%%================================================================================
%% behavior callbacks
%%================================================================================

all() ->
  [Fun || {Fun, 1} <- ?MODULE:module_info(exports), lists:prefix("t_", atom_to_list(Fun))].

init_per_suite(Config) ->
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
     #{timetrap => 10000},
     try
       application:ensure_all_started(?APP),
       ?block_until(#{?snk_kind := sysmon_report_data})
     after
       application:stop(?APP)
     end,
     []).

%%================================================================================
%% Internal functions
%%================================================================================
