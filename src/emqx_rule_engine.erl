%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_rule_engine).

-include("rule_engine.hrl").
-include_lib("emqx/include/logger.hrl").

-export([ load_providers/0
        , unload_providers/0
        , refresh_resources/0
        , refresh_rules/0
        , refresh_resource_status/0
        ]).

-export([ create_rule/1
        , delete_rule/1
        , create_resource/1
        , test_resource/1
        , start_resource/1
        , get_resource_status/1
        , get_resource_params/1
        , delete_resource/1
        ]).

-export([ init_resource/4
        , init_action/4
        , clear_resource/3
        , clear_action/3
        ]).

-type(rule() :: #rule{}).
-type(action() :: #action{}).
-type(resource() :: #resource{}).
-type(resource_type() :: #resource_type{}).
-type(resource_params() :: #resource_params{}).
-type(action_instance_params() :: #action_instance_params{}).

-export_type([ rule/0
             , action/0
             , resource/0
             , resource_type/0
             , resource_params/0
             , action_instance_params/0
             ]).

-define(ALARM_ID_RES_DOWN(RES_ID), <<"resource_down/", RES_ID/binary>>).

%%------------------------------------------------------------------------------
%% Load resource/action providers from all available applications
%%------------------------------------------------------------------------------

%% Load all providers .
-spec(load_providers() -> ok).
load_providers() ->
    [load_provider(App) || App <- ignore_lib_apps(application:loaded_applications())],
    ok.

-spec(load_provider(App :: atom()) -> ok).
load_provider(App) when is_atom(App) ->
    ok = load_actions(App),
    ok = load_resource_types(App).

%%------------------------------------------------------------------------------
%% Unload providers
%%------------------------------------------------------------------------------
%% Load all providers .
-spec(unload_providers() -> ok).
unload_providers() ->
    [unload_provider(App) || App <- ignore_lib_apps(application:loaded_applications())],
    ok.

%% @doc Unload a provider.
-spec(unload_provider(App :: atom()) -> ok).
unload_provider(App) ->
    ok = emqx_rule_registry:remove_actions_of(App),
    ok = emqx_rule_registry:unregister_resource_types_of(App).

load_actions(App) ->
    Actions = find_actions(App),
    emqx_rule_registry:add_actions(Actions).

load_resource_types(App) ->
    ResourceTypes = find_resource_types(App),
    emqx_rule_registry:register_resource_types(ResourceTypes).

-spec(find_actions(App :: atom()) -> list(action())).
find_actions(App) ->
    lists:map(fun new_action/1, find_attrs(App, rule_action)).

-spec(find_resource_types(App :: atom()) -> list(resource_type())).
find_resource_types(App) ->
    lists:map(fun new_resource_type/1, find_attrs(App, resource_type)).

new_action({App, Mod, #{name := Name,
                        for := Hook,
                        types := Types,
                        create := Create,
                        params := ParamsSpec} = Params}) ->
    ok = emqx_rule_validator:validate_spec(ParamsSpec),
    #action{name = Name, for = Hook, app = App, types = Types,
            module = Mod, on_create = Create,
            hidden = maps:get(hidden, Params, false),
            on_destroy = maps:get(destroy, Params, undefined),
            params_spec = ParamsSpec,
            title = maps:get(title, Params, ?descr),
            description = maps:get(description, Params, ?descr)}.

new_resource_type({App, Mod, #{name := Name,
                               params := ParamsSpec,
                               create := Create} = Params}) ->
    ok = emqx_rule_validator:validate_spec(ParamsSpec),
    #resource_type{name = Name, provider = App,
                   params_spec = ParamsSpec,
                   on_create = {Mod, Create},
                   on_status = {Mod, maps:get(status, Params, undefined)},
                   on_destroy = {Mod, maps:get(destroy, Params, undefined)},
                   title = maps:get(title, Params, ?descr),
                   description = maps:get(description, Params, ?descr)}.

find_attrs(App, Def) ->
    [{App, Mod, Attr} || {ok, Modules} <- [application:get_key(App, modules)],
                         Mod <- Modules,
                         {Name, Attrs} <- module_attributes(Mod), Name =:= Def,
                         Attr <- Attrs].

module_attributes(Module) ->
    try Module:module_info(attributes)
    catch
        error:undef -> [];
        error:Reason -> error(Reason)
    end.

%%------------------------------------------------------------------------------
%% APIs for rules and resources
%%------------------------------------------------------------------------------

-spec(create_rule(#{}) -> {ok, rule()} | no_return()).
create_rule(Params = #{rawsql := Sql, actions := Actions}) ->
    case emqx_rule_sqlparser:parse_select(Sql) of
        {ok, Select} ->
            RuleId = rule_id(),
            Rule = #rule{id = RuleId,
                         rawsql = Sql,
                         for = emqx_rule_sqlparser:select_from(Select),
                         is_foreach = emqx_rule_sqlparser:select_is_foreach(Select),
                         fields = emqx_rule_sqlparser:select_fields(Select),
                         doeach = emqx_rule_sqlparser:select_doeach(Select),
                         incase = emqx_rule_sqlparser:select_incase(Select),
                         conditions = emqx_rule_sqlparser:select_where(Select),
                         actions = [prepare_action(Action) || Action <- Actions],
                         enabled = maps:get(enabled, Params, true),
                         description = maps:get(description, Params, "")},
            ok = emqx_rule_registry:add_rule(Rule),
            {ok, Rule};
        Error -> error(Error)
    end.

-spec(delete_rule(RuleId :: rule_id()) -> ok).
delete_rule(RuleId) ->
    case emqx_rule_registry:get_rule(RuleId) of
        {ok, #rule{actions = Actions}} ->
            lists:foreach(
                fun(#action_instance{id = Id, name = ActName}) ->
                    {ok, #action{module = Mod, on_destroy = Destory}} = emqx_rule_registry:find_action(ActName),
                    cluster_call(clear_action, [Mod, Destory, Id])
                end, Actions),
            emqx_rule_metrics:clear(RuleId),
            emqx_rule_registry:remove_rule(RuleId);
        not_found ->
            ok
    end.

-spec(create_resource(#{}) -> {ok, resource()} | {error, Reason :: term()}).
create_resource(#{type := Type, config := Config} = Params) ->
    case emqx_rule_registry:find_resource_type(Type) of
        {ok, #resource_type{on_create = {M, F}, params_spec = ParamSpec}} ->
            ok = emqx_rule_validator:validate_params(Config, ParamSpec),
            ResId = resource_id(),
            Resource = #resource{id = ResId,
                                 type = Type,
                                 config = Config,
                                 description = iolist_to_binary(maps:get(description, Params, ""))},
            ok = emqx_rule_registry:add_resource(Resource),
            %% Note that we will return OK in case of resource creation failure,
            %% users can always re-start the resource later.
            catch cluster_call(init_resource, [M, F, ResId, Config]),
            {ok, Resource};
        not_found ->
            {error, {resource_type_not_found, Type}}
    end.

-spec(start_resource(resource_id()) -> ok | {error, Reason :: term()}).
start_resource(ResId) ->
    case emqx_rule_registry:find_resource(ResId) of
        {ok, #resource{type = ResType, config = Config}} ->
            {ok, #resource_type{on_create = {Mod, Create}}}
                = emqx_rule_registry:find_resource_type(ResType),
            init_resource(Mod, Create, ResId, Config),
            refresh_actions_of_a_resource(ResId),
            ok;
        not_found ->
            {error, {resource_not_found, ResId}}
    end.

-spec(test_resource(#{}) -> ok | {error, Reason :: term()}).
test_resource(#{type := Type, config := Config}) ->
    case emqx_rule_registry:find_resource_type(Type) of
        {ok, #resource_type{on_create = {ModC,Create}, on_destroy = {ModD,Destroy}, params_spec = ParamSpec}} ->
            ok = emqx_rule_validator:validate_params(Config, ParamSpec),
            ResId = resource_id(),
            cluster_call(init_resource, [ModC, Create, ResId, Config]),
            cluster_call(clear_resource, [ModD, Destroy, ResId]),
            ok;
        not_found ->
            {error, {resource_type_not_found, Type}}
    end.

-spec(get_resource_status(resource_id()) -> {ok, resource_status()} | {error, Reason :: term()}).
get_resource_status(ResId) ->
    case emqx_rule_registry:find_resource(ResId) of
        {ok, #resource{type = ResType}} ->
            {ok, #resource_type{on_status = {Mod, OnStatus}}}
                = emqx_rule_registry:find_resource_type(ResType),
            Status = fetch_resource_status(Mod, OnStatus, ResId),
            {ok, Status};
        not_found ->
            {error, {resource_not_found, ResId}}
    end.

-spec(get_resource_params(resource_id()) -> {ok, map()} | {error, Reason :: term()}).
get_resource_params(ResId) ->
     case emqx_rule_registry:find_resource_params(ResId) of
        {ok, #resource_params{params = Params}} ->
            {ok, Params};
        not_found ->
            {error, resource_not_initialized}
    end.

-spec(delete_resource(resource_id()) -> ok | {error, Reason :: term()}).
delete_resource(ResId) ->
    case emqx_rule_registry:find_resource(ResId) of
        {ok, #resource{type = ResType}} ->
            {ok, #resource_type{on_destroy = {ModD,Destroy}}}
                = emqx_rule_registry:find_resource_type(ResType),
            ok = emqx_rule_registry:remove_resource(ResId),
            cluster_call(clear_resource, [ModD, Destroy, ResId]);
        not_found ->
            {error, {resource_not_found, ResId}}
    end.

%%------------------------------------------------------------------------------
%% Re-establish resources
%%------------------------------------------------------------------------------

-spec(refresh_resources() -> ok).
refresh_resources() ->
    try
        lists:foreach(
            fun(#resource{id = ResId, config = Config, type = Type}) ->
                {ok, #resource_type{on_create = {M, F}}} = emqx_rule_registry:find_resource_type(Type),
                cluster_call(init_resource, [M, F, ResId, Config])
            end, emqx_rule_registry:get_resources())
    catch
        _:Error:StackTrace ->
            logger:critical("Can not re-stablish resource: ~p,"
                            "Fix the issue and establish it manually.\n"
                            "Stacktrace: ~p",
                            [Error, StackTrace])
    end.

-spec(refresh_rules() -> ok).
refresh_rules() ->
    try
        [lists:foreach(
            fun(#action_instance{id = Id, name = ActName, args = Args}) ->
                {ok, #action{module = Mod, on_create = Create}} = emqx_rule_registry:find_action(ActName),
                cluster_call(init_action, [Mod, Create, Id, with_resource_params(Args)])
            end, Actions)
        || #rule{actions = Actions} <- emqx_rule_registry:get_rules()],
        ok
    catch
        _:Error:StackTrace ->
            logger:critical("Can not re-build rule: ~p,"
                            "Fix the issue and establish it manually.\n"
                            "Stacktrace: ~p",
                            [Error, StackTrace])
    end.

-spec(refresh_resource_status() -> ok).
refresh_resource_status() ->
    lists:foreach(
        fun(#resource{id = ResId, type = ResType}) ->
            case emqx_rule_registry:find_resource_type(ResType) of
                {ok, #resource_type{on_status = {Mod, OnStatus}}} ->
                    fetch_resource_status(Mod, OnStatus, ResId);
                _ -> ok
            end
        end, emqx_rule_registry:get_resources()).

%%------------------------------------------------------------------------------
%% Internal Functions
%%------------------------------------------------------------------------------

prepare_action({Name, Args}) ->
    case emqx_rule_registry:find_action(Name) of
        {ok, #action{module = Mod, on_create = Create, params_spec = ParamSpec}} ->
            ok = emqx_rule_validator:validate_params(Args, ParamSpec),
            ActionInstId = action_instance_id(Name),
            cluster_call(init_action, [Mod, Create, ActionInstId, with_resource_params(Args)]),
            #action_instance{id = ActionInstId, name = Name, args = Args};
        not_found ->
            throw({action_not_found, Name})
    end.

with_resource_params(Args = #{<<"$resource">> := ResId}) ->
    case emqx_rule_registry:find_resource_params(ResId) of
        {ok, #resource_params{params = Params}} ->
            maps:merge(Args, Params);
        not_found ->
            throw({resource_not_initialized, ResId})
    end;
with_resource_params(Args) -> Args.

ignore_lib_apps(Apps) ->
    LibApps = [kernel, stdlib, sasl, appmon, eldap, erts,
               syntax_tools, ssl, crypto, mnesia, os_mon,
               inets, goldrush, gproc, runtime_tools,
               snmp, otp_mibs, public_key, asn1, ssh, hipe,
               common_test, observer, webtool, xmerl, tools,
               test_server, compiler, debugger, eunit, et,
               wx],
    [AppName || {AppName, _, _} <- Apps, not lists:member(AppName, LibApps)].

resource_id() ->
    gen_id("resource:", fun emqx_rule_registry:find_resource/1).

rule_id() ->
    gen_id("rule:", fun emqx_rule_registry:get_rule/1).

gen_id(Prefix, TestFun) ->
    Id = iolist_to_binary([Prefix, emqx_rule_id:gen()]),
    case TestFun(Id) of
        not_found -> Id;
        _Res -> gen_id(Prefix, TestFun)
    end.

action_instance_id(ActionName) ->
    iolist_to_binary([atom_to_list(ActionName), "_", integer_to_list(erlang:system_time())]).

cluster_call(Func, Args) ->
    case rpc:multicall([node() | nodes()], ?MODULE, Func, Args, 5000) of
        {ResL, []} ->
            case lists:filter(fun(ok) -> false; (_) -> true end, ResL) of
                [] -> ok;
                ErrL ->
                    ?LOG(error, "cluster_call error found, ResL: ~p", [ResL]),
                    throw({func_fail(Func), ErrL})
            end;
        {ResL, BadNodes} ->
            ?LOG(error, "cluster_call bad nodes found: ~p, ResL: ~p", [BadNodes, ResL]),
            throw({func_fail(Func), {nodes_not_exist, BadNodes}})
   end.

init_resource(Module, OnCreate, ResId, Config) ->
    Params = ?RAISE(Module:OnCreate(ResId, Config),
                    {{init_resource_failure, node()}, {{Module, OnCreate}, _REASON_}}),
    emqx_rule_registry:add_resource_params(#resource_params{id = ResId, params = Params}).

init_action(Module, OnCreate, ActionInstId, Params) ->
    case ?RAISE(Module:OnCreate(ActionInstId, Params), {{init_action_failure, node()}, {{Module,OnCreate},_REASON_}}) of
        {Apply, NewParams} ->
            ok = emqx_rule_registry:add_action_instance_params(
                #action_instance_params{id = ActionInstId, params = NewParams, apply = Apply});
        Apply ->
            ok = emqx_rule_registry:add_action_instance_params(
                #action_instance_params{id = ActionInstId, params = Params, apply = Apply})
    end.

clear_resource(_Module, undefined, ResId) ->
    ok = emqx_rule_registry:remove_resource_params(ResId);
clear_resource(Module, Destroy, ResId) ->
    case emqx_rule_registry:find_resource_params(ResId) of
        {ok, #resource_params{params = Params}} ->
            ?RAISE(Module:Destroy(ResId, Params),
                   {{destroy_resource_failure, node()}, {{Module, Destroy}, _REASON_}}),
            ok = emqx_rule_registry:remove_resource_params(ResId);
        not_found ->
            ok
    end.

clear_action(_Module, undefined, ActionInstId) ->
    emqx_rule_metrics:clear(ActionInstId),
    ok = emqx_rule_registry:remove_action_instance_params(ActionInstId);
clear_action(Module, Destroy, ActionInstId) ->
    emqx_rule_metrics:clear(ActionInstId),
    case emqx_rule_registry:get_action_instance_params(ActionInstId) of
        {ok, #action_instance_params{params = Params}} ->
            ?RAISE(Module:Destroy(ActionInstId, Params),{{destroy_action_failure, node()},
                                           {{Module, Destroy}, _REASON_}}),
            ok = emqx_rule_registry:remove_action_instance_params(ActionInstId);
        not_found ->
            ok
    end.

fetch_resource_status(Module, OnStatus, ResId) ->
    case emqx_rule_registry:find_resource_params(ResId) of
        {ok, ResParams = #resource_params{params = Params, status = #{is_alive := LastIsAlive}}} ->
            try
                NewStatus =
                    case Module:OnStatus(ResId, Params) of
                        #{is_alive := LastIsAlive} = Status -> Status;
                        #{is_alive := true} = Status ->
                            alarm_handler:clear_alarm(?ALARM_ID_RES_DOWN(ResId)),
                            Status;
                        #{is_alive := false} = Status ->
                            alarm_handler:set_alarm({?ALARM_ID_RES_DOWN(ResId), "Resource Down"}),
                            Status
                    end,
                emqx_rule_registry:add_resource_params(ResParams#resource_params{status = NewStatus}),
                NewStatus
            catch _Error:Reason:STrace ->
                ?LOG(error, "get resource status for ~p failed: ~0p", [ResId, {Reason, STrace}]),
                #{is_alive => false}
            end;
        not_found ->
            #{is_alive => false}
    end.

refresh_actions_of_a_resource(ResId) ->
    [lists:foreach(
        fun(#action_instance{args = Args = #{<<"$resource">> := ResId0},
                             id = Id, name = ActName}) when ResId0 =:= ResId ->
                {ok, #action{module = Mod, on_create = Create}}
                    = emqx_rule_registry:find_action(ActName),
                init_action(Mod, Create, Id, with_resource_params(Args));
            (#action_instance{}) ->
                ok
        end, Actions)
    || #rule{actions = Actions} <- emqx_rule_registry:get_rules()].

func_fail(Func) when is_atom(Func) ->
    list_to_atom(atom_to_list(Func) ++ "_failure").
