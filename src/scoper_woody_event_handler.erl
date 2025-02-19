-module(scoper_woody_event_handler).

%% Commented out to compile the module without woody
%% -behaviour(woody_event_handler).

%% woody_event_handler behaviour callbacks
-export([handle_event/4]).

-ignore_xref({woody_event_handler, get_event_severity, 3}).
-ignore_xref({woody_event_handler, format_meta, 3}).
-ignore_xref({woody_event_handler, format_event, 3}).
-ignore_xref({woody_event_handler_otel, handle_event, 4}).

-type options() :: #{
    event_handler_opts => woody_event_handler:options()
}.

-export_type([options/0]).

%%
%% woody_event_handler behaviour callbacks
%%
-spec handle_event(Event, RpcID, Meta, Opts) -> ok when
    Event :: woody_event_handler:event(),
    RpcID :: woody:rpc_id() | undefined,
    Meta :: woody_event_handler:event_meta(),
    Opts :: options().
handle_event(Event, RpcID, Meta, Opts) ->
    ok = before_event(Event, RpcID, Meta, Opts),
    _ = handle_event_(Event, RpcID, Meta, Opts),
    ok = after_event(Event, RpcID, Meta, Opts).

%% Otel wraps

-define(IS_START_EVENT(Event),
    (Event =:= 'client begin' orelse
        Event =:= 'call service' orelse
        Event =:= 'client send' orelse
        Event =:= 'client resolve begin' orelse
        Event =:= 'client cache begin' orelse
        Event =:= 'server receive' orelse
        Event =:= 'invoke service handler')
).

-define(IS_SPECIAL_EVENT(Event),
    (Event =:= 'internal error' orelse
        Event =:= 'trace event')
).

before_event(Event, RpcID, Meta, Opts) when ?IS_START_EVENT(Event) orelse ?IS_SPECIAL_EVENT(Event) ->
    woody_event_handler_otel:handle_event(Event, RpcID, Meta, Opts);
before_event(_Event, _RpcID, _Meta, _Opts) ->
    ok.

after_event(Event, RpcID, Meta, Opts) when not (?IS_START_EVENT(Event) orelse ?IS_SPECIAL_EVENT(Event)) ->
    woody_event_handler_otel:handle_event(Event, RpcID, Meta, Opts);
after_event(_Event, _RpcID, _Meta, _Opts) ->
    ok.

%% Scope handling

%% client scoping
handle_event_('client begin', _RpcID, _Meta, _Opts) ->
    scoper:add_scope(get_scope_name(client));
handle_event_('client cache begin', _RpcID, _Meta, _Opts) ->
    scoper:add_scope(get_scope_name(caching_client));
handle_event_('client end', _RpcID, _Meta, _Opts) ->
    scoper:remove_scope();
handle_event_('client cache end', _RpcID, _Meta, _Opts) ->
    scoper:remove_scope();
%% server scoping
handle_event_('server receive' = Event, RpcID, RawMeta, Opts) ->
    ok = add_server_meta(RpcID),
    do_handle_event(Event, RpcID, RawMeta, Opts);
handle_event_('server send' = Event, RpcID, RawMeta, Opts) ->
    ok = do_handle_event(Event, RpcID, RawMeta, Opts),
    remove_server_meta();
%% special cases
handle_event_('internal error' = Event, RpcID, RawMeta, Opts) ->
    ok = do_handle_event(Event, RpcID, RawMeta, Opts),
    final_error_cleanup(RawMeta);
handle_event_('trace event' = Event, RpcID, #{role := Role} = RawMeta, Opts) ->
    case lists:member(get_scope_name(Role), scoper:get_scope_names()) of
        true ->
            do_handle_event(Event, RpcID, RawMeta, Opts);
        false ->
            scoper:scope(
                get_scope_name(Role),
                fun() -> do_handle_event(Event, RpcID, RawMeta, Opts) end
            )
    end;
%% the rest
handle_event_(Event, RpcID, RawMeta, Opts) ->
    do_handle_event(Event, RpcID, RawMeta, Opts).

%%
%% Internal functions
%%

-define(REQUISITE_META, [
    event,
    service,
    function,
    type,
    metadata,
    url,
    deadline,
    execution_duration_ms
]).

do_handle_event(Event, RpcID, #{role := Role} = EvMeta, Opts) ->
    EvHandlerOptions = get_event_handler_options(Opts),
    Level = woody_event_handler:get_event_severity(Event, EvMeta, EvHandlerOptions),
    Meta = woody_event_handler:format_meta(Event, EvMeta, ?REQUISITE_META),
    ok = scoper:add_meta(Meta),
    log_event(Level, Event, Role, EvMeta, RpcID, Opts);
do_handle_event(_Event, _RpcID, _RawMeta, _Opts) ->
    ok.

-if(OTP_RELEASE >= 24).

log_event(Level, Event, Role, EvMeta, RpcID, Opts) ->
    logger:log(Level, fun do_format_event/1, {Event, Role, EvMeta, RpcID, Opts}).

do_format_event({Event, Role, EvMeta, RpcID, Opts}) ->
    EvHandlerOptions = get_event_handler_options(Opts),
    Format = woody_event_handler:format_event(Event, EvMeta, EvHandlerOptions),
    LogMeta = collect_md(Role, RpcID),
    {Format, LogMeta}.

-else.

log_event(Level, Event, Role, EvMeta, RpcID, Opts) ->
    LogMeta = collect_md(Role, RpcID),
    logger:log(Level, fun do_format_event/1, {Event, EvMeta, Opts}, LogMeta).

do_format_event({Event, EvMeta, Opts}) ->
    EvHandlerOptions = get_event_handler_options(Opts),
    woody_event_handler:format_event(Event, EvMeta, EvHandlerOptions).

-endif.

%% Log metadata should contain rpc ID properties (trace_id, span_id and parent_id)
%% _on the top level_ according to the requirements.
%% In order to add rpc ID to log messages from woody handler, it is stored
%% in lager:md() in case of woody server. Since woody client can be invoked during
%% processing of parent request by a woody server handler, rpc ID of the child request
%% is added directly to the log meta before logging. It is _not stored_ in lager:md()
%% in that case, so child rpc ID does not override parent rpc ID
%% for the server handler processing context.
collect_md(client, RpcID) ->
    collect_md(add_rpc_id(RpcID, scoper:collect()));
collect_md(server, _RpcID) ->
    collect_md(scoper:collect()).

collect_md(MD) ->
    MD#{pid => self()}.

get_scope_name(client) ->
    'rpc.client';
get_scope_name(caching_client) ->
    'rpc.caching_client';
get_scope_name(server) ->
    'rpc.server'.

final_error_cleanup(#{role := server, error := _, final := true}) ->
    remove_server_meta();
final_error_cleanup(_) ->
    ok.

add_server_meta(RpcID) ->
    ok = scoper:add_scope(get_scope_name(server)),
    logger:set_process_metadata(add_rpc_id(RpcID, scoper:collect())).

remove_server_meta() ->
    _ =
        case scoper:get_current_scope() of
            'rpc.server' ->
                ok;
            _ ->
                logger:warning(
                    "Scoper woody event handler: removing uncleaned scopes on the server: ~p",
                    [scoper:get_scope_names()]
                )
        end,
    ok = scoper:clear().

add_rpc_id(undefined, MD) ->
    MD;
add_rpc_id(RpcID, MD) ->
    maps:merge(MD, RpcID).

%% Pass event_handler_opts only
get_event_handler_options(#{event_handler_opts := EventHandlerOptions}) ->
    EventHandlerOptions;
get_event_handler_options(_Opts) ->
    #{}.
