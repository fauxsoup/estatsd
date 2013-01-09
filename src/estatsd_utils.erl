%% ================================================================
%% @author          Zachary Hueras
%% @version         0.0.1
%% @doc             Miscellaneous shared functions.
%% ================================================================
-module(estatsd_utils).
-export([appvar/2]).
-export([do_incr/3, do_push/3]).
-export([unixtime/0, unixtime/1]).
-export([num_to_str/1]).
-export([bin_to_hash/1]).

%% @doc Returns the estatsd environment variable K, or Def
%% if the key is undefined.
-spec appvar(K :: atom(), Def :: undefined | term()) -> term().
appvar(K, Def) ->
    case application:get_env(estatsd, K) of
        {ok, Val} -> Val;
        undefined -> Def
    end.

%% @doc Attempts to update the counter for the key; if this fails,
%% assume the failure resulted because the key does not exist, then
%% use increment_new/3
-spec do_incr(Tid :: term(), Key :: atom() | string(), Amount :: integer()) -> integer().
do_incr(Tid, Key, Amount) ->
    case catch neural:increment(Tid, Key, {2, Amount}) of
        N when is_integer(N) ->
            N;
        _ ->
            make_new(Tid, Key, Amount, fun do_incr/3)
    end.

%% @doc Attempts to insert a new key into Tid; if this fails, assume
%% the failure resulted because another process beat us to it, then
%% go back to do_incr.
-spec make_new(Tid :: term(), Key :: atom() | string(), Value :: integer(), F :: function()) -> integer().
make_new(Tid, Key, Value, F) ->
    case neural:insert_new(Tid, {Key, Value}) of
        false -> 
            F(Tid, Key, Value);
        true when is_list(Value) -> 
            length(Value);
        true when is_integer(Value) ->
            Value
    end.

do_push(Tid, Key, Values) ->
    case catch neural:unshift(Tid, Key, {2, Values}) of
        N when is_integer(N) ->
            N;
        _ ->
            make_new(Tid, Key, Values, fun do_push/3)
    end.

unixtime() -> unixtime(os:timestamp()).
unixtime({M, S, _}) -> (M * 1000000) + S.

num_to_str(NN) -> lists:flatten(io_lib:format("~w",[NN])).

bin_to_hash(Bin) when is_binary(Bin) ->
    bin_to_hash(Bin, []).

bin_to_hash(<<>>, R) ->
    string:to_lower(lists:flatten(lists:reverse(R)));
bin_to_hash(<<C,T/binary>>, R) ->
    bin_to_hash(T, [string:right(integer_to_list(C,16),2,$0)|R]).
