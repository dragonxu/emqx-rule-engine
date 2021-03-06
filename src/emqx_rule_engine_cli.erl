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

-module(emqx_rule_engine_cli).

-include("rule_engine.hrl").

-export([ load/0
        , commands/0
        , unload/0
        ]).

-export([ rules/1
        , actions/1
        , resources/1
        , resource_types/1
        ]).

-import(proplists, [get_value/2]).

-define(OPTSPEC_RESOURCE_TYPE,
        [{type, $t, "type", {atom, undefined}, "Resource Type"}]).
-define(OPTSPEC_ACTION_TYPE,
        [ {eventype, $k, "eventype", {atom, undefined}, "Event Type"}
        ]).

-define(OPTSPEC_RESOURCES_CREATE,
        [ {type, undefined, undefined, atom, "Resource Type"}
        , {config, $c, "config", {binary, <<"{}">>}, "Config"}
        , {descr, $d, "descr", {binary, <<"">>}, "Description"}
        ]).

-define(OPTSPEC_RULES_CREATE,
        [ {sql, undefined, undefined, binary, "Filter Condition SQL"}
        , {actions, undefined, undefined, binary, "Action List in JSON format: [{\"name\": <action_name>, \"params\": {<key>: <value>}}]"}
        , {descr, $d, "descr", {binary, <<"">>}, "Description"}
        ]).

%%-----------------------------------------------------------------------------
%% Load/Unload Commands
%%-----------------------------------------------------------------------------

-spec(load() -> ok).
load() ->
    lists:foreach(
      fun({Cmd, Func}) ->
              emqx_ctl:register_command(Cmd, {?MODULE, Func}, []);
         (Cmd) ->
              emqx_ctl:register_command(Cmd, {?MODULE, Cmd}, [])
      end, commands()).

-spec(commands() -> list(atom())).
commands() ->
    [rules, {'rule-actions', actions}, resources, {'resource-types', resource_types}].

-spec(unload() -> ok).
unload() ->
    lists:foreach(
      fun({Cmd, _Func}) ->
              emqx_ctl:unregister_command(Cmd);
         (Cmd) ->
              emqx_ctl:unregister_command(Cmd)
      end, commands()).

%%-----------------------------------------------------------------------------
%% 'rules' command
%%-----------------------------------------------------------------------------

rules(["list"]) ->
    print_all(emqx_rule_registry:get_rules());

rules(["show", RuleId]) ->
    print_with(fun emqx_rule_registry:get_rule/1, list_to_binary(RuleId));

rules(["create" | Params]) ->
    with_opts(fun({Opts, _}) ->
                try emqx_rule_engine:create_rule(make_rule(Opts)) of
                    {ok, #rule{id = RuleId}} ->
                        emqx_ctl:print("Rule ~s created~n", [RuleId]);
                    {error, Reason} ->
                        emqx_ctl:print("Invalid options: ~0p~n", [Reason])
                catch
                    throw:Error ->
                        emqx_ctl:print("Invalid options: ~0p~n", [Error])
                end
              end, Params, ?OPTSPEC_RULES_CREATE, {?FUNCTION_NAME, create});

rules(["delete", RuleId]) ->
    ok = emqx_rule_engine:delete_rule(list_to_binary(RuleId)),
    emqx_ctl:print("ok~n");

rules(_usage) ->
    emqx_ctl:usage([{"rules list",          "List all rules"},
                    {"rules show <RuleId>", "Show a rule"},
                    {"rules create", "Create a rule"},
                    {"rules delete <RuleId>", "Delete a rule"}
                    ]).

%%-----------------------------------------------------------------------------
%% 'rule-actions' command
%%-----------------------------------------------------------------------------

actions(["list"]) ->
    print_all(get_actions());

actions(["show", ActionId]) ->
    print_with(fun emqx_rule_registry:find_action/1, ?RAISE(list_to_existing_atom(ActionId), {not_found, ActionId}));

actions(_usage) ->
    emqx_ctl:usage([{"rule-actions list",            "List actions"},
                    {"rule-actions show <ActionId>", "Show a rule action"}
                    ]).

%%------------------------------------------------------------------------------
%% 'resources' command
%%------------------------------------------------------------------------------
resources(["create" | Params]) ->
    with_opts(fun({Opts, _}) ->
                try emqx_rule_engine:create_resource(make_resource(Opts)) of
                    {ok, #resource{id = ResId}} ->
                        emqx_ctl:print("Resource ~s created~n", [ResId]);
                    {error, Reason} ->
                        emqx_ctl:print("Invalid options: ~0p~n", [Reason])
                catch
                    throw:Reason ->
                        emqx_ctl:print("Invalid options: ~0p~n", [Reason])
                end
              end, Params, ?OPTSPEC_RESOURCES_CREATE, {?FUNCTION_NAME, create});

resources(["test" | Params]) ->
    with_opts(fun({Opts, _}) ->
                try emqx_rule_engine:test_resource(make_resource(Opts)) of
                    ok ->
                        emqx_ctl:print("Test creating resource successfully (dry-run)~n");
                    {error, Reason} ->
                        emqx_ctl:print("Test creating resource failed: ~0p~n", [Reason])
                catch
                    throw:Reason ->
                        emqx_ctl:print("Test creating resource failed: ~0p~n", [Reason])
                end
              end, Params, ?OPTSPEC_RESOURCES_CREATE, {?FUNCTION_NAME, test});

resources(["list"]) ->
    print_all(emqx_rule_registry:get_resources());

resources(["list" | Params]) ->
    with_opts(fun({Opts, _}) ->
            print_all(emqx_rule_registry:get_resources_by_type(
                get_value(type, Opts)))
        end, Params, ?OPTSPEC_RESOURCE_TYPE, {?FUNCTION_NAME, list});

resources(["show", ResourceId]) ->
    print_with(fun emqx_rule_registry:find_resource/1, list_to_binary(ResourceId));

resources(["delete", ResourceId]) ->
    try
        ok = emqx_rule_engine:delete_resource(list_to_binary(ResourceId)),
        emqx_ctl:print("ok~n")
    catch
        _Error:Reason ->
            emqx_ctl:print("Cannot delete resource as ~0p~n", [Reason])
    end;

resources(_usage) ->
    emqx_ctl:usage([{"resources create", "Create a resource"},
                    {"resources list [-t <ResourceType>]", "List resources"},
                    {"resources show <ResourceId>", "Show a resource"},
                    {"resources delete <ResourceId>", "Delete a resource"}
                   ]).

%%------------------------------------------------------------------------------
%% 'resource-types' command
%%------------------------------------------------------------------------------
resource_types(["list"]) ->
    print_all(emqx_rule_registry:get_resource_types());

resource_types(["show", Name]) ->
    print_with(fun emqx_rule_registry:find_resource_type/1, list_to_atom(Name));

resource_types(_usage) ->
    emqx_ctl:usage([{"resource-types list", "List all resource-types"},
                    {"resource-types show <Type>", "Show a resource-type"}
                   ]).

%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

print(Data) ->
    emqx_ctl:print(untilde(format(Data))).

print_all(DataList) ->
    lists:map(fun(Data) ->
            print(Data)
        end, DataList).

print_with(FindFun, Key) ->
    case FindFun(Key) of
        {ok, R} ->
            print(R);
        not_found ->
            emqx_ctl:print("Cannot found ~s~n", [Key])
    end.

format(#rule{id = Id,
             for = Hook,
             rawsql = Sql,
             actions = Actions,
             enabled = Enabled,
             description = Descr}) ->
    lists:flatten(io_lib:format("rule(id='~s', for='~0p', rawsql='~s', actions=~0p, metrics=~0p, enabled='~s', description='~s')~n", [Id, Hook, rmlf(Sql), printable_actions(Actions), get_rule_metrics(Id), Enabled, Descr]));

format(#action{hidden = true}) ->
    ok;
format(#action{name = Name,
               for = Hook,
               app = App,
               types = Types,
               title = #{en := Title},
               description = #{en := Descr}}) ->
    lists:flatten(io_lib:format("action(name='~s', app='~s', for='~s', types=~0p, title ='~s', description='~s')~n", [Name, App, Hook, Types, Title, Descr]));

format(#resource{id = Id,
                 type = Type,
                 config = Config,
                 description = Descr}) ->
    Status =
        [begin
            {ok, St} = rpc:call(Node, emqx_rule_engine, get_resource_status, [Id]),
            maps:put(node, Node, St)
        end || Node <- [node()| nodes()]],
    lists:flatten(io_lib:format("resource(id='~s', type='~s', config=~0p, status=~0p, description='~s')~n", [Id, Type, Config, Status, Descr]));

format(#resource_type{name = Name,
                      provider = Provider,
                      title = #{en := Title},
                      description = #{en := Descr}}) ->
    lists:flatten(io_lib:format("resource_type(name='~s', provider='~s', title ='~s', description='~s')~n", [Name, Provider, Title, Descr])).

make_rule(Opts) ->
    Actions = get_value(actions, Opts),
    #{rawsql => get_value(sql, Opts),
      actions => parse_action_params(Actions),
      description => get_value(descr, Opts)}.

make_resource(Opts) ->
    Config = get_value(config, Opts),
    #{type => get_value(type, Opts),
      config => ?RAISE(emqx_json:decode(Config, [return_maps]), {invalid_config, Config}),
      description => get_value(descr, Opts)}.

printable_actions(Actions) when is_list(Actions) ->
    emqx_json:encode([#{id => Id, name => Name, params => Args, metrics => get_action_metrics(Id)}
                      || #action_instance{id = Id, name = Name, args = Args} <- Actions]).

with_opts(Action, RawParams, OptSpecList, {CmdObject, CmdName}) ->
    case getopt:parse_and_check(OptSpecList, RawParams) of
        {ok, Params} ->
            Action(Params);
        {error, Reason} ->
            getopt:usage(OptSpecList,
                io_lib:format("emqx_ctl ~s ~s", [CmdObject, CmdName]), standard_io),
            emqx_ctl:print("~0p~n", [Reason])
    end.

parse_action_params(Actions) ->
    ?RAISE(
        lists:map(fun
            (#{<<"name">> := ActName, <<"params">> := ActParam}) ->
                {?RAISE(binary_to_existing_atom(ActName, utf8), {action_not_found, ActName}),
                ActParam};
            (#{<<"name">> := ActName}) ->
                {?RAISE(binary_to_existing_atom(ActName, utf8), {action_not_found, ActName}), #{}}
            end, emqx_json:decode(Actions, [return_maps])),
        {invalid_action_params, _REASON_}).

get_actions() ->
    emqx_rule_registry:get_actions().

get_rule_metrics(Id) ->
    [maps:put(node, Node, rpc:call(Node, emqx_rule_metrics, get_rule_metrics, [Id]))
     || Node <- [node()| nodes()]].

get_action_metrics(Id) ->
    [maps:put(node, Node, rpc:call(Node, emqx_rule_metrics, get_action_metrics, [Id]))
     || Node <- [node()| nodes()]].

rmlf(Str) ->
    re:replace(Str, "\n", "", [global]).

untilde(Str) ->
    re:replace(Str,"~","&&",[{return,list}, global]).
