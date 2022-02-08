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
-module(system_monitor_pg).

-behaviour(gen_server).
-export([ start_link/0
        , init/1
        , handle_continue/2
        , handle_call/3
        , handle_info/2
        , handle_cast/2
        , format_status/2
        , terminate/2

        , connect_options/0
        ]).

-behaviour(system_monitor_callback).
-export([ start/0, stop/0, produce/2 ]).

-include("sysmon_int.hrl").
-include_lib("kernel/include/logger.hrl").

-define(SERVER, ?MODULE).
-define(FIVE_SECONDS, 5000).
-define(ONE_HOUR, 60*60*1000).

%%%_* API =================================================================
start() ->
  {ok, _} = system_monitor_sup:start_child(?MODULE),
  ok.

stop() ->
  gen_server:stop(?SERVER).

produce(Type, Events) ->
  gen_server:cast(?SERVER, {produce, Type, Events}).

%%%_* Callbacks =================================================================
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init(_Args) ->
  erlang:process_flag(trap_exit, true),
  logger:update_process_metadata(#{domain => [system_monitor, pg]}),
  {ok, #{}, {continue, start_pg}}.

handle_continue(start_pg, State) ->
  Conn = initialize(),
  case Conn of
    undefined ->
      timer:send_after(?FIVE_SECONDS, reinitialize);
    Conn ->
      ok
  end,
  timer:send_after(?ONE_HOUR, mk_partitions),
  {noreply, State#{connection => Conn}}.

handle_call(_Msg, _From, State) ->
  {reply, ok, State}.

handle_info({'EXIT', Conn, _Reason}, #{connection := Conn} = State) ->
  timer:send_after(?FIVE_SECONDS, reinitialize),
  {noreply, State};
handle_info({'EXIT', _Conn, _Reason}, #{connection := undefined} = State) ->
  timer:send_after(?FIVE_SECONDS, reinitialize),
  {noreply, State};
handle_info({'EXIT', _Conn, normal}, State) ->
  {noreply, State};
handle_info(mk_partitions, #{connection := undefined} = State) ->
  timer:send_after(?ONE_HOUR, mk_partitions),
  {noreply, State};
handle_info(mk_partitions, #{connection := Conn} = State) ->
  mk_partitions(Conn),
  timer:send_after(?ONE_HOUR, mk_partitions),
  {noreply, State};
handle_info(reinitialize, State) ->
  {noreply, State#{connection => initialize()}}.

handle_cast({produce, _Type, _Events}, #{connection := undefined} = State) ->
  {noreply, State};
handle_cast({produce, Type, Events}, #{connection := Conn} = State) ->
  MaxMsgQueueSize = application:get_env(?APP, max_message_queue_len, 1000),
  case process_info(self(), message_queue_len) of
    {_, N} when N > MaxMsgQueueSize ->
      ignore;
    _ ->
      run_query(Conn, Type, Events)
  end,
  {noreply, State}.

format_status(normal, [_PDict, State]) ->
  [{data, [{"State", State}]}];
format_status(terminate, [_PDict, State]) ->
  State.

terminate(_Reason, #{connection := undefined}) ->
  ok;
terminate(_Reason, #{connection := Conn}) ->
  epgsql:close(Conn).

%%%_* Internal functions ======================================================

run_query(Conn, Type, Events) ->
  {ok, Statement} = epgsql:parse(Conn, query(Type)),
  Batch   = [{Statement, params(Type, I)} || I <- Events],
  Results = epgsql:execute_batch(Conn, Batch),
  emit_traces(Type, Events, Results).

emit_traces(_Type, [], []) ->
  ok;
emit_traces(Type, [_Evt|Evts], [Result|Results]) ->
  case Result of
    {error, Err} ->
      ?tp(debug, system_monitor_pg_query_error,
          #{ query => Type
           , error => Err
           });
    _Ok ->
      ?tp(sysmon_produce, #{ type    => Type
                           , msg     => _Evt
                           , backend => pg
                           })
  end,
  emit_traces(Type, Evts, Results).

initialize() ->
  case connect() of
    undefined ->
      undefined;
    Conn ->
      mk_partitions(Conn),
      Conn
  end.

connect() ->
  case epgsql:connect(connect_options()) of
    {ok, Conn} ->
      Conn;
    Err ->
      ?LOG_WARNING("Failed to open connection to the DB: ~p", [Err]),
      undefined
  end.

connect_options() ->
  #{host => ?CFG(db_hostname),
    port => ?CFG(db_port),
    username => ?CFG(db_username),
    password => ?CFG(db_password),
    database => ?CFG(db_name),
    timeout => ?CFG(db_connection_timeout),
    codecs => []
   }.

mk_partitions(Conn) ->
  DaysAhead = application:get_env(system_monitor, partition_days_ahead, 10),
  DaysBehind = application:get_env(system_monitor, partition_days_behind, 10),
  GDate = calendar:date_to_gregorian_days(date()),
  DaysAheadL = lists:seq(GDate, GDate + DaysAhead),
  %% Delete 10 days older than partition_days_behind config
  DaysBehindL = lists:seq(GDate - DaysBehind - 10, GDate - DaysBehind - 1),
  lists:foreach(fun(Day) -> create_partition_tables(Conn, Day) end, DaysAheadL),
  lists:foreach(fun(Day) -> delete_partition_tables(Conn, Day) end, DaysBehindL).

create_partition_tables(Conn, Day) ->
  Tables = [<<"prc">>, <<"app_top">>, <<"initial_fun_top">>, <<"current_fun_top">>, <<"node_status">>],
  From = to_postgres_date(Day),
  To = to_postgres_date(Day + 1),
  lists:foreach(fun(Table) ->
                    Query = create_partition_query(Table, Day, From, To),
                    [{ok, [], []}, {ok, [], []}] = epgsql:squery(Conn, Query)
                end,
                Tables).

delete_partition_tables(Conn, Day) ->
  Tables = [<<"prc">>, <<"app_top">>, <<"fun_top">>, <<"node_status">>],
  lists:foreach(fun(Table) ->
                   Query = delete_partition_query(Table, Day),
                   {ok, [], []} = epgsql:squery(Conn, Query)
                end,
                Tables).

create_partition_query(Table, Day, From, To) ->
  <<"CREATE TABLE IF NOT EXISTS ", Table/binary, "_", (integer_to_binary(Day))/binary, " ",
    "PARTITION OF ", Table/binary, " ",
    "FOR VALUES "
    "FROM ('", (list_to_binary(From))/binary, "') TO ('", (list_to_binary(To))/binary, "');"
    "CREATE INDEX IF NOT EXISTS ",
    Table/binary, "_", (integer_to_binary(Day))/binary, "_ts_idx "
    "ON ", Table/binary, "_", (integer_to_binary(Day))/binary, "(ts);">>.

delete_partition_query(Table, Day) ->
  <<"DROP TABLE IF EXISTS ", Table/binary, "_", (integer_to_binary(Day))/binary, ";">>.

to_postgres_date(GDays) ->
  {YY, MM, DD} = calendar:gregorian_days_to_date(GDays),
  lists:flatten(io_lib:format("~w-~2..0w-~2..0w", [YY, MM, DD])).

query(initial_fun_top) ->
  fun_top_query("initial");
query(current_fun_top) ->
  fun_top_query("current");
query(app_top) ->
  app_top_query();
query(node_status) ->
  node_status_query();
query(proc_top) ->
  prc_query().

prc_query() ->
  <<"insert into prc (node, ts, pid, dreductions, dmemory, reductions, "
    "memory, message_queue_len, current_function, initial_call, "
    "registered_name, stack_size, heap_size, total_heap_size, current_stacktrace, group_leader) "
    "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16);">>.

app_top_query() ->
  <<"insert into app_top (node, ts, application, red_abs, red_rel, memory, num_processes)"
    " VALUES ($1, $2, $3, $4, $5, $6, $7);">>.

fun_top_query(Top) ->
  iolist_to_binary(
    [<<"insert into ">>,
     Top,
     <<"_fun_top(node, ts, fun, percent_processes) VALUES ($1, $2, $3, $4);">>]).

node_status_query() ->
  <<"insert into node_status (node, ts, data) VALUES ($1, $2, $3);">>.

params(Top, {Node, TS, Function, PercentProcesses}) when Top =:= initial_fun_top;
                                                         Top =:= current_fun_top ->
  [atom_to_list(Node),
   ts_to_timestamp(TS),
   system_monitor_lib:fmt_mfa(Function),
   PercentProcesses];
params(app_top,
       #app_top{app = App,
                ts = TS,
                red_abs = RedAbs,
                red_rel = RedRel,
                memory = Mem,
                processes = NumProcesses
               }) ->
  [atom_to_binary(node(), latin1),
   ts_to_timestamp(TS),
   atom_to_binary(App, latin1),
   RedAbs,
   RedRel,
   Mem,
   NumProcesses];
params(node_status, {node_status, Node, TS, Bin}) ->
  [atom_to_list(Node), ts_to_timestamp(TS), Bin];
params(proc_top,
       #erl_top{ts = TS,
                pid = Pid,
                dreductions = DR,
                dmemory = DM,
                reductions = R,
                memory = M,
                message_queue_len = MQL,
                current_function = CF,
                initial_call = IC,
                registered_name = RN,
                stack_size = SS,
                heap_size = HS,
                total_heap_size = THS,
                current_stacktrace = CS,
                group_leader = GL} =
         _Event) ->
  [atom_to_binary(node(), latin1),
   ts_to_timestamp(TS),
   Pid,
   DR,
   DM,
   R,
   M,
   MQL,
   system_monitor_lib:fmt_mfa(CF),
   system_monitor_lib:fmt_mfa(IC),
   name_to_list(RN),
   SS,
   HS,
   THS,
   system_monitor_lib:fmt_stack(CS),
   GL].

ts_to_timestamp(TS) ->
  calendar:system_time_to_universal_time(TS, ?TS_UNIT).

name_to_list(Term) ->
  case io_lib:printable_latin1_list(Term) of
    true ->
      Term;
    false ->
      lists:flatten(io_lib:format("~p", [Term]))
  end.
