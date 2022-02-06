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
-module(system_monitor_top).

%% API:
-export([empty/1, push/3, to_list/1]).

-export_type([top/0]).

-ifdef(TEST).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif. % TEST

%%================================================================================
%% Type declarations
%%================================================================================

-record(top,
        { minimum  :: non_neg_integer()
        , size     :: non_neg_integer()
        , max_size :: non_neg_integer()
        , data     :: gb_trees:tree(non_neg_integer(), [tuple()])
        }).

-opaque top() :: #top{}.

%%================================================================================
%% API funcions
%%================================================================================

-spec empty(non_neg_integer()) -> top().
empty(MaxItems) ->
  #top{ minimum  = 0
      , size     = 0
      , max_size = MaxItems
      , data     = gb_trees:empty()
      }.

-spec to_list(top()) -> [tuple()].
to_list(#top{data = Data}) ->
  lists:append(gb_trees:values(Data)).

-spec push(integer(), tuple(), top()) -> top().
push(_, _, Top = #top{max_size = 0}) ->
  Top;
push(FieldID, Val, #top{ size     = Size
                       , max_size = MaxSize
                       , data     = Data0
                       }) when Size < MaxSize ->
  Key      = element(FieldID, Val),
  Data     = gb_insert(Key, Val, Data0),
  {Min, _} = gb_trees:smallest(Data),
  #top{ size     = Size + 1
      , max_size = MaxSize
      , minimum  = Min
      , data     = Data
      };
push(FieldID, Val,
     OldTop = #top{ minimum  = OldMin
                  , data     = Data0
                  , max_size = MaxSize
                  }) ->
  Key = element(FieldID, Val),
  if OldMin < Key ->
      {SKey, SVal, Data1} = gb_trees:take_smallest(Data0),
      case SVal of
        [_] ->
          Data2 = Data1;
        [_|SVal2] ->
          Data2 = gb_trees:enter(SKey, SVal2, Data1)
      end,
      Data = gb_insert(Key, Val, Data2),
      {Min, _} = gb_trees:smallest(Data),
      #top{ minimum  = Min
          , size     = MaxSize
          , max_size = MaxSize
          , data     = Data
          };
    true ->
      OldTop
  end.

%%================================================================================
%% Internal functions
%%================================================================================

gb_insert(Key, Val, Tree) ->
  case gb_trees:lookup(Key, Tree) of
    none ->
      gb_trees:enter(Key, [Val], Tree);
    {value, Vals} ->
      gb_trees:update(Key, [Val|Vals], Tree)
  end.

%%%===================================================================
%%% Tests
%%%===================================================================

-ifdef(TEST).

tuples() ->
  list({non_neg_integer()}).

%% maybe_push_to_top function is just an optimized version
%% of sorting a list and then taking its first N elements.
%%
%% Check that it is indeed true
maybe_push_to_top_same_as_sort_prop() ->
  ?FORALL({NItems, L}, {range(0, 10), tuples()},
          ?IMPLIES(
             length(L) >= NItems,
             begin
               Reference = lists:nthtail(length(L) - NItems, lists:sort(L)),
               Top = lists:foldl( fun(I, Acc) -> push(1, I, Acc) end
                                , empty(NItems)
                                , L
                                ),
               ?assertEqual(Reference, to_list(Top)),
               true
             end)).

maybe_push_to_top_test() ->
  ?assertEqual(true, proper:quickcheck(
                       proper:numtests(
                         1000,
                         maybe_push_to_top_same_as_sort_prop())
                      )).

-endif.
