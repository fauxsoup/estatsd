%% Stats aggregation process that periodically dumps data to graphite
%% Will calculate 90th percentile etc.
%% Inspired by etsy statsd:
%% http://codeascraft.etsy.com/2011/02/15/measure-anything-measure-everything/
%%
%% This could be extended to take a callback for reporting mechanisms.
%% Right now it's hardcoded to stick data into graphite.
%%
%% Richard Jones <rj@metabrew.com>
%%
-module(estatsd_server).
-behaviour(gen_leader).
-compile([{parse_transform, ct_expand}]).
-export([start_link/0]).
-include("estatsd.hrl").

-export([node_key/0,key2str/1]).%,flush/0]). %% export for debugging 

-export([init/1, handle_call/4, handle_cast/3, handle_info/2,
         handle_leader_call/4, handle_leader_cast/3, handle_DOWN/3,
         elected/3, surrendered/3, from_leader/3, terminate/2,
         code_change/4]).

-record(state, {
        flush_interval      = 10000,            % ms interval between stats flushing
        last_flush          = os:timestamp(),   % erlang-style timestamp of last flush (or start time)
        flush_timer         = undefined,        % TRef of interval timer
        destination         = undefined,        % What to do every flush interval
        is_leader           = false,
        aggregate           = [],
        enable_node_tagging = false,
        node_tagging        = [],
        cluster_tagging     = [],
        vm_metrics          = true              % flag to enable sending VM metrics on flush
    }).

start_link() ->
    Nodes = case application:get_env(estatsd, peers) of
        undefined -> [node()];
        {ok, Peers} -> Peers
    end,
    gen_leader:start_link(?MODULE, Nodes, [], ?MODULE, [], [{spawn_opt, [{priority, high}]}]).

%%

init([]) ->
    % 1. Initialize our state.
    State = #state{flush_interval = FlushInterval} = init_state(),

    % 3. Create two tables each for gauges and counters; double-buffer mentality :)
    % Use duplicate bags to accomodate multiple entries for each key in gauge and timer tables
    % Optimize for write operations
    neural:new(statsd_counters_agg, []),
    neural:new(statsd_gauge_agg, []),
    neural:new(statsd_timer_agg, []),
    neural:new(statsd_counter, []),
    neural:new(statsd_gauge, []),
    neural:new(statsd_timer, []),

    % 5. Set a timer to flush stats
    {ok, Tref} = timer:apply_interval(FlushInterval, gen_leader, cast, [?MODULE, flush]),

    {ok, State#state{flush_timer = Tref}}.

init_state() ->
    NodeTagging     = parse_tagging(estatsd_utils:appvar(node_tagging, [])),
    ClusterTagging  = parse_tagging(estatsd_utils:appvar(cluster_tagging, [])),
    #state{ 
        flush_interval      = estatsd_utils:appvar(flush_interval, 10000),
        destination         = estatsd_utils:appvar(destination,  {graphite, "127.0.0.1", 2003}),
        vm_metrics          = estatsd_utils:appvar(vm_metrics,  false),
        enable_node_tagging = estatsd_utils:appvar(enable_node_tagging, false),
        node_tagging        = NodeTagging,
        cluster_tagging     = ClusterTagging
    }.

parse_tagging(Tagging) ->
    [ parse_tag(Tag) || Tag <- Tagging ].

parse_tag({KeyRX, Type, Position, Affix}) ->
    {ok, RX} = re:compile(KeyRX),
    {RX, Type, Position, parse_affix(Affix)}.

parse_affix(node_key)   -> node_key();
parse_affix(String)     -> String.

elected(State, _Election, undefined) ->
    Synch = [],
    {ok, Synch, State#state{is_leader = true}};
elected(State, _Election, _Node) ->
    {reply, [], State}.

surrendered(State = #state{aggregate = VMs}, _Sync, _Election) ->
    Counters    = neural:drain(statsd_counters_agg),
    Gauges      = neural:drain(statsd_gauge_agg),
    Timers      = neural:drain(statsd_timer_agg),

    estatsd:aggregate(Counters, Gauges, Timers, VMs),

    {ok, State#state{is_leader = false, aggregate = []}}.

handle_cast(flush, State = #state{aggregate = Aggregate}, _Election) ->
    % 3. Gather data
    All     = get_counters(State),
    Gauges  = get_gauges(State),
    Timers  = get_timers(State), % Timers are a duplicate bag
    VM      = get_vm_metrics(Aggregate, State),

    % 4. Do reports
    CurrTime = os:timestamp(),
    do_report(All, Timers, Gauges, VM, CurrTime, State),

    % 6. Update state to flip tables internally
    NewState = State#state{
        last_flush      = CurrTime,                     % Also, update the last flush so our calculations are, you know, accurate.
        aggregate       = []
    },
    {noreply, NewState}.

handle_leader_cast({aggregate, Counters, Timers, Gauges, VMs}, State = #state{aggregate = Aggregate}, _Election) ->
    lists:foreach(fun({K, V}) -> estatsd_utils:do_incr(statsd_counters_agg, K, V) end, Counters),
    lists:foreach(fun({K, V}) -> estatsd_utils:do_push(statsd_gauge_agg, K, V) end, Gauges),
    lists:foreach(fun({K, V}) -> estatsd_utils:do_push(statsd_timer_agg, K, V) end, Timers),
    {noreply, State#state{aggregate = Aggregate ++ VMs}};
handle_leader_cast(_Cast, State, _Election) ->
    {noreply, State}.

handle_call(_Call,_,State, _Election) -> 
    {reply, ok, State}.

handle_leader_call(_Call, _From, State, _Election) ->
    {reply, ok, State}.

handle_info(_Msg, State) -> 
    {noreply, State}.

handle_DOWN(_Node, State, _Election) ->
    {ok, State}.

from_leader(_Synch, State, _Election) ->
    {ok, State}.

code_change(_, _, State, _Election) -> 
    {noreply, State}.

terminate(_, _) -> 
    ok.

%% INTERNAL STUFF
get_counters(_State = #state{is_leader = false, enable_node_tagging = false}) ->
    [ {key2str(K),V} || {K,V} <- neural:drain(statsd_counter) ];
get_counters(_State = #state{is_leader = false, enable_node_tagging = true, node_tagging = []}) ->
    [ {key2str(K),V} || {K,V} <- neural:drain(statsd_counter) ];
get_counters(_State = #state{is_leader = false, enable_node_tagging = true, node_tagging = NodeTagging}) ->
    tag_metrics(neural:drain(statsd_counter), NodeTagging);
get_counters(State = #state{is_leader = true}) ->
    LocalCounters = get_counters(State#state{is_leader = false}),
    lists:foreach(fun({K, V}) -> estatsd_utils:do_incr(statsd_counters_agg, K, V) end, LocalCounters),
    neural:drain(statsd_counters_agg).

get_timers(_State = #state{is_leader = false, enable_node_tagging = false}) ->
    [ {key2str(K),V} || {K,V} <- neural:drain(statsd_timer) ];
get_timers(_State = #state{is_leader = false, enable_node_tagging = true, node_tagging = []}) ->
    [ {key2str(K),V} || {K,V} <- neural:drain(statsd_timer) ];
get_timers(_State = #state{is_leader = false, enable_node_tagging = true, node_tagging = NodeTagging}) ->
    tag_metrics(neural:drain(statsd_timer), NodeTagging);
get_timers(State = #state{is_leader = true}) ->
    LocalTimers = get_timers(State#state{is_leader = false}),
    lists:foreach(fun({K, V}) -> estatsd_utils:do_push(statsd_timer_agg, K, V) end, LocalTimers),
    neural:drain(statsd_timer_agg).
    
get_gauges(_State = #state{is_leader = false, enable_node_tagging = false}) ->
    [ {key2str(K), V} || {K,V} <- neural:drain(statsd_gauge) ];
get_gauges(_State = #state{is_leader = false, enable_node_tagging = true, node_tagging = []}) ->
    [ {key2str(K), V} || {K,V} <- neural:drain(statsd_gauge) ];
get_gauges(_State = #state{is_leader = false, enable_node_tagging = true, node_tagging = NodeTagging}) ->
    tag_metrics(neural:drain(statsd_gauge), NodeTagging);
get_gauges(State = #state{is_leader = true}) ->
    LocalGauges = get_gauges(State#state{is_leader = false}),
    lists:foreach(fun({K, V}) -> estatsd_utils:do_push(statsd_gauge_agg, K, V) end, LocalGauges),
    neural:drain(statsd_gauge_agg).

%% Don't apply node tagging rules for VM stats. They are not
%% user-generated keys.
get_vm_metrics(Aggregate, _State = #state{vm_metrics = false}) ->
    Aggregate;
get_vm_metrics(_Aggregate, _State = #state{is_leader = false}) ->
    [{node_key(), get_local_metrics()}];
get_vm_metrics(Aggregate, State = #state{is_leader = true}) ->
    [LocalMetrics] = get_vm_metrics([], State#state{is_leader = false}),
    [LocalMetrics|Aggregate].

get_local_metrics() ->
    {TotalReductions, Reductions} = erlang:statistics(reductions),
    {NumberOfGCs, WordsReclaimed, _} = erlang:statistics(garbage_collection),
    {{input, Input}, {output, Output}} = erlang:statistics(io),
    RunQueue = erlang:statistics(run_queue),
    StatsData = [
                 {"process_count", erlang:system_info(process_count)},
                 {"reductions", Reductions},
                 {"total_reductions", TotalReductions},
                 {"number_of_gcs", NumberOfGCs},
                 {"words_reclaimed", WordsReclaimed},
                 {"input", Input},
                 {"output", Output},
                 {"run_queue", RunQueue}
                ],
    MemoryData = erlang:memory(),
    {StatsData, MemoryData}.

send_to_graphite(Msg, GraphiteHost, GraphitePort) ->
    case gen_tcp:connect(GraphiteHost, GraphitePort, [list, {packet, 0}]) of
        {ok, Sock} ->
            gen_tcp:send(Sock, Msg),
            gen_tcp:close(Sock),
            ok;
        E ->
%            error_logger:error_msg("Failed to connect to graphite: ~p", [E]),
            E
    end.

% this string munging is damn ugly compared to javascript :(
key2str(K) when is_atom(K) -> 
    atom_to_list(K);
key2str(K) when is_binary(K) -> 
    key2str(binary_to_list(K));
key2str(K) when is_list(K) ->
    Opts = [global, {return, list}],
    lists:foldl(fun({Rx, Replace}, S) -> re:replace(S, Rx, Replace, Opts) end, K, [
            {?COMPILE_ONCE("\\s+"), "_"},
            {?COMPILE_ONCE("/"), "-"},
            {?COMPILE_ONCE("[^a-zA-Z_\\-0-9\\.]"), ""}
        ]).

do_report(All, Timers, Gauges, VM, CurrTime, State = #state{is_leader = true, cluster_tagging = ClusterTagging = [_|_]}) ->
    {All1, Timers1, Gauges1} = tag_metrics({All, Timers, Gauges}, ClusterTagging),
    do_report(All1, Timers1, Gauges1, VM, CurrTime, State#state{cluster_tagging = []});
do_report(All, Timers, Gauges, VM, CurrTime, State = #state{is_leader = true, destination = {graphite, GraphiteHost, GraphitePort}}) ->
    % One time stamp string used in all stats lines:
    Duration                        = timer:now_diff(CurrTime, State#state.last_flush) / 1000000,
    TsStr                           = estatsd_utils:num_to_str(estatsd_utils:unixtime(CurrTime)),
    {MsgCounters, NumCounters}      = do_report_counters(TsStr, All, Duration),
    {MsgTimers, NumTimers}          = do_report_timers(TsStr, Timers),
    {MsgGauges, NumGauges}          = do_report_gauges(Gauges),
    {MsgVmMetrics, NumVmMetrics}    = do_report_vm_metrics(VM, TsStr, State),
    %% REPORT TO GRAPHITE
    case NumTimers + NumCounters + NumGauges + NumVmMetrics of
        0 -> 
            nothing_to_report;
        NumStats ->
            FinalMsg = [ MsgCounters,
                         MsgTimers,
                         MsgGauges,
                         MsgVmMetrics,
                         %% Also graph the number of graphs we're graphing:
                         "stats.num_stats ", estatsd_utils:num_to_str(NumStats), " ", TsStr, "\n"
                       ],
            send_to_graphite(FinalMsg, GraphiteHost, GraphitePort)
    end;
%% TODO: Make everything below this point less atrocious.
do_report(All, Timers, Gauges, VM, _CurrTime, _State = #state{is_leader = true, destination = Destination}) ->
    estatsd_tcp:send(Destination, All, Timers, Gauges, VM);
do_report(All, Timers, Gauges, VM, _CurrTime, _State = #state{is_leader = false}) ->
    estatsd:aggregate(All, Timers, Gauges, VM).

tag_metrics(Metrics, Tags) when is_list(Metrics) ->
    lists:foldl(fun apply_tags/2, Metrics, Tags);
tag_metrics(Metrics, Tags) when is_tuple(Metrics) ->
    list_to_tuple([ lists:foldl(fun apply_tags/2, Values, Tags) || Values <- tuple_to_list(Metrics) ]).

apply_tags(Tag, Values) ->
    lists:foldl(fun(Value, Acc) -> apply_tag(Tag, Value, Acc) end, [], Values).

apply_tag({KeyPattern, copy, Position, Affix}, {Key0, Value}, Acc) ->
    Key = key2str(Key0),
    case re:run(Key, KeyPattern, [{capture, none}]) of
        match   -> [{affix(Key, Position, Affix), Value}, {Key, Value} | Acc];
        nomatch -> [{Key, Value} | Acc]
    end;
apply_tag({KeyPattern, replace, Position, Affix}, {Key0, Value}, Acc) ->
    Key = key2str(Key0),
    case re:run(Key, KeyPattern, [{capture, none}]) of
        match   -> [{affix(Key, Position, Affix), Value}|Acc];
        nomatch -> [{Key, Value}|Acc]
    end.

affix(Key, prefix, Affix) ->
    key2str([Affix, ".", Key]);
affix(Key, suffix, Affix) ->
    key2str([Key, ".", Affix]).

do_report_counters(TsStr, All, Duration) ->
    Msg = lists:foldl(
                fun({Key, Val0}, Acc) ->
                        KeyS = key2str(Key),
                        Val = Val0 / Duration,
                        %% Build stats string for graphite
                        Fragment = [ "stats.counters.", KeyS, " ", 
                                     io_lib:format("~w", [Val]), " ", 
                                     TsStr, "\n",

                                     "stats.counters.counts.", KeyS, " ", 
                                     io_lib:format("~w",[Val0]), " ", 
                                     TsStr, "\n"
                                   ],
                        [ Fragment | Acc ]                    
                end, [], All),
    {Msg, length(All)}.

do_report_timers(TsStr, Timings) ->
    Msg = lists:foldl(
        fun({Key, Vals}, Acc) ->
                KeyS = key2str(Key),
                Values          = lists:sort(Vals),
                Count           = length(Values),
                Min             = hd(Values),
                Max             = lists:last(Values),
                PctThreshold    = 90,
                ThresholdIndex  = erlang:round(((100-PctThreshold)/100)*Count),
                NumInThreshold  = Count - ThresholdIndex,
                Values1         = lists:sublist(Values, NumInThreshold),
                MaxAtThreshold  = lists:nth(NumInThreshold, Values),
                Mean            = lists:sum(Values1) / case NumInThreshold of 0 -> 1; _ -> NumInThreshold end,
                %% Build stats string for graphite
                Startl          = [ "stats.timers.", KeyS, "." ],
                Endl            = [" ", TsStr, "\n"],
                Fragment        = [ [Startl, Name, " ", estatsd_utils:num_to_str(Val), Endl] || {Name,Val} <-
                                  [ {"mean", Mean},
                                    {"upper", Max},
                                    {"upper_"++estatsd_utils:num_to_str(PctThreshold), MaxAtThreshold},
                                    {"lower", Min},
                                    {"count", Count}
                                  ]],
                [ Fragment | Acc ]
        end, [], Timings),
    {Msg, length(Msg)}.

do_report_gauges(Gauges) ->
    Msg = lists:foldl(
        fun({Key, Vals}, Acc) ->
            KeyS = key2str(Key),
            Fragments = lists:foldl(
                fun ({Val, TS}, KeyAcc) ->
                    %% Build stats string for graphite
                    Fragment = [
                        "stats.gauges.", KeyS, " ",
                        io_lib:format("~w", [Val]), " ",
                        integer_to_list(TS), "\n"
                    ],
                    [ Fragment | KeyAcc ]
                end, [], Vals
            ),
            [ Fragments | Acc ]
        end, [], Gauges
    ),
    {Msg, length(Gauges)}.

do_report_vm_metrics(VMs, TsStr, State) ->
    case State#state.vm_metrics of
        true ->
            {TsStr, Msg, C} = lists:foldl(fun build_vm_stats/2, {TsStr, [], 0}, VMs),
            {Msg, C};
        false ->
            {[], 0}
    end.

build_vm_stats({NodeKey, {StatsData, MemoryData}}, {TsStr, Acc, C}) ->
    StatsMsg = lists:map(fun({Key, Val}) ->
        [
         "stats.vm.", NodeKey, ".stats.", key2str(Key), " ",
         io_lib:format("~w", [Val]), " ",
         TsStr, "\n"
        ]
    end, StatsData),
    MemoryMsg = lists:map(fun({Key, Val}) ->
        [
         "stats.vm.", NodeKey, ".memory.", key2str(Key), " ",
         io_lib:format("~w", [Val]), " ",
         TsStr, "\n"
        ]
    end, MemoryData),
    NumStats = length(StatsData) + length(MemoryData),
    Msg = [StatsMsg, MemoryMsg],
    {TsStr, [Acc, Msg], C + NumStats}.

node_key() ->
    NodeList = atom_to_list(node()),
    {ok, R} = re:compile("[\@\.]"),
    Opts = [global, {return, list}],
    S = re:replace(NodeList,  R, "_", Opts),
    key2str(S).
