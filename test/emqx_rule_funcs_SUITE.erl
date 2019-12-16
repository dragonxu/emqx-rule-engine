%%--------------------------------------------------------------------
%% Copyright (c) 2019 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_rule_funcs_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(PROPTEST(F), ?assert(proper:quickcheck(F()))).
%%-define(PROPTEST(F), ?assert(proper:quickcheck(F(), [{on_output, fun ct:print/2}]))).

%%------------------------------------------------------------------------------
%% Test cases for IoT Funcs
%%------------------------------------------------------------------------------

t_msgid(_) ->
    Msg = message(),
    ?assertEqual(undefined, apply_func(msgid, [], #{})),
    ?assertEqual(emqx_guid:to_hexstr(emqx_message:id(Msg)), apply_func(msgid, [], Msg)).

t_qos(_) ->
    ?assertEqual(undefined, apply_func(qos, [], #{})),
    ?assertEqual(1, apply_func(qos, [], message())).

t_flags(_) ->
    ?assertEqual(#{dup => false}, apply_func(flags, [], message())).

t_flag(_) ->
    Msg = message(),
    Msg1 = emqx_message:set_flag(retain, Msg),
    ?assertNot(apply_func(flag, [dup], Msg)),
    ?assert(apply_func(flag, [retain], Msg1)).

t_topic(_) ->
    Msg = message(),
    ?assertEqual(<<"topic/#">>, apply_func(topic, [], Msg)),
    ?assertEqual(<<"topic">>, apply_func(topic, [1], Msg)).

t_clientid(_) ->
    Msg = message(),
    ?assertEqual(undefined, apply_func(clientid, [], #{})),
    ?assertEqual(<<"clientid">>, apply_func(clientid, [], Msg)).

t_clientip(_) ->
    Msg = emqx_message:set_header(peerhost, {127,0,0,1}, message()),
    ?assertEqual(undefined, apply_func(clientip, [], #{})),
    ?assertEqual(<<"127.0.0.1">>, apply_func(clientip, [], Msg)).

t_peerhost(_) ->
    Msg = emqx_message:set_header(peerhost, {127,0,0,1}, message()),
    ?assertEqual(undefined, apply_func(peerhost, [], #{})),
    ?assertEqual(<<"127.0.0.1">>, apply_func(peerhost, [], Msg)).

t_username(_) ->
    Msg = emqx_message:set_header(username, <<"feng">>, message()),
    ?assertEqual(<<"feng">>, apply_func(username, [], Msg)).

t_payload(_) ->
    Input = emqx_message:to_map(message()),
    NestedMap = #{a => #{b => #{c => c}}},
    ?assertEqual(<<"hello">>, apply_func(payload, [], Input#{payload => <<"hello">>})),
    ?assertEqual(c, apply_func(payload, [<<"a.b.c">>], Input#{payload => NestedMap})).

t_timestamp(_) ->
    Now = erlang:system_time(millisecond),
    timer:sleep(100),
    ?assert(Now < apply_func(timestamp, [], message())).

%%------------------------------------------------------------------------------
%% Data Type Convertion Funcs
%%------------------------------------------------------------------------------
t_str(_) ->
    ?assertEqual(<<"abc">>, emqx_rule_funcs:str("abc")),
    ?assertEqual(<<"abc">>, emqx_rule_funcs:str(abc)),
    ?assertEqual(<<"{\"a\":1}">>, emqx_rule_funcs:str(#{a => 1})),
    ?assertEqual(<<"1">>, emqx_rule_funcs:str(1)),
    ?assertEqual(<<"2.0">>, emqx_rule_funcs:str(2.0)),
    ?assertEqual(<<"true">>, emqx_rule_funcs:str(true)),
    ?assertError(_, emqx_rule_funcs:str({a, v})),

    ?assertEqual(<<"abc">>, emqx_rule_funcs:str_utf8("abc")),
    ?assertEqual(<<"abc 你好"/utf8>>, emqx_rule_funcs:str_utf8("abc 你好")),
    ?assertEqual(<<"abc 你好"/utf8>>, emqx_rule_funcs:str_utf8(<<"abc 你好"/utf8>>)),
    ?assertEqual(<<"abc">>, emqx_rule_funcs:str_utf8(abc)),
    ?assertEqual(<<"{\"a\":\"abc 你好\"}"/utf8>>, emqx_rule_funcs:str_utf8(#{a => <<"abc 你好"/utf8>>})),
    ?assertEqual(<<"1">>, emqx_rule_funcs:str_utf8(1)),
    ?assertEqual(<<"2.0">>, emqx_rule_funcs:str_utf8(2.0)),
    ?assertEqual(<<"true">>, emqx_rule_funcs:str_utf8(true)),
    ?assertError(_, emqx_rule_funcs:str_utf8({a, v})).

t_int(_) ->
    ?assertEqual(1, emqx_rule_funcs:int("1")),
    ?assertEqual(1, emqx_rule_funcs:int(<<"1.0">>)),
    ?assertEqual(1, emqx_rule_funcs:int(1)),
    ?assertEqual(1, emqx_rule_funcs:int(1.9)),
    ?assertEqual(1, emqx_rule_funcs:int(1.0001)),
    ?assertEqual(1, emqx_rule_funcs:int(true)),
    ?assertEqual(0, emqx_rule_funcs:int(false)),
    ?assertError({invalid_number, {a, v}}, emqx_rule_funcs:int({a, v})),
    ?assertError(_, emqx_rule_funcs:int("a")).

t_float(_) ->
    ?assertEqual(1.0, emqx_rule_funcs:float("1.0")),
    ?assertEqual(1.0, emqx_rule_funcs:float(<<"1.0">>)),
    ?assertEqual(1.0, emqx_rule_funcs:float(1)),
    ?assertEqual(1.0, emqx_rule_funcs:float(1.0)),
    ?assertEqual(1.9, emqx_rule_funcs:float(1.9)),
    ?assertEqual(1.0001, emqx_rule_funcs:float(1.0001)),
    ?assertEqual(1.0000000001, emqx_rule_funcs:float(1.0000000001)),
    ?assertError({invalid_number, {a, v}}, emqx_rule_funcs:float({a, v})),
    ?assertError(_, emqx_rule_funcs:float("a")).

t_map(_) ->
    ?assertEqual(#{ver => <<"1.0">>, name => "emqx"}, emqx_rule_funcs:map([{ver, <<"1.0">>}, {name, "emqx"}])),
    ?assertEqual(#{<<"a">> => 1}, emqx_rule_funcs:map(<<"{\"a\":1}">>)),
    ?assertError(_, emqx_rule_funcs:map(<<"a">>)),
    ?assertError(_, emqx_rule_funcs:map("a")),
    ?assertError(_, emqx_rule_funcs:map(1.0)).

t_bool(_) ->
    ?assertEqual(true, emqx_rule_funcs:bool(1)),
    ?assertEqual(true, emqx_rule_funcs:bool(1.0)),
    ?assertEqual(false, emqx_rule_funcs:bool(0)),
    ?assertEqual(false, emqx_rule_funcs:bool(0.0)),
    ?assertEqual(true, emqx_rule_funcs:bool(true)),
    ?assertEqual(true, emqx_rule_funcs:bool(<<"true">>)),
    ?assertEqual(false, emqx_rule_funcs:bool(false)),
    ?assertEqual(false, emqx_rule_funcs:bool(<<"false">>)),
    ?assertError({invalid_boolean, _}, emqx_rule_funcs:bool(3)).

%%------------------------------------------------------------------------------
%% Test cases for arith op
%%------------------------------------------------------------------------------

t_arith_op(_) ->
    ?PROPTEST(prop_arith_op).

prop_arith_op() ->
    ?FORALL({X, Y}, {number(), number()},
            begin
                (X + Y) == apply_func('+', [X, Y]) andalso
                (X - Y) == apply_func('-', [X, Y]) andalso
                (X * Y) == apply_func('*', [X, Y]) andalso
                (if Y =/= 0 ->
                        (X / Y) == apply_func('/', [X, Y]);
                    true -> true
                 end) andalso
                (case is_integer(X)
                     andalso is_pos_integer(Y) of
                     true ->
                         (X rem Y) == apply_func('mod', [X, Y]);
                     false -> true
                end)
            end).

is_pos_integer(X) ->
    is_integer(X) andalso X > 0.

%%------------------------------------------------------------------------------
%% Test cases for math fun
%%------------------------------------------------------------------------------

t_math_fun(_) ->
    ?PROPTEST(prop_math_fun).

prop_math_fun() ->
    Excluded = [module_info, atanh, asin, acos],
    MathFuns = [{F, A} || {F, A} <- math:module_info(exports),
                          not lists:member(F, Excluded),
                          erlang:function_exported(emqx_rule_funcs, F, A)],
    ?FORALL({X, Y}, {pos_integer(), pos_integer()},
            begin
                lists:foldl(fun({F, 1}, True) ->
                                    True andalso comp_with_math(F, X);
                               ({F = fmod, 2}, True) ->
                                    True andalso (if Y =/= 0 ->
                                                         comp_with_math(F, X, Y);
                                                     true -> true
                                                  end);
                               ({F, 2}, True) ->
                                    True andalso comp_with_math(F, X, Y)
                            end, true, MathFuns)
            end).

comp_with_math(exp, X) ->
    if X < 710 -> math:exp(X) == apply_func(exp, [X]);
       true -> true
    end;
comp_with_math(F, X) ->
    math:F(X) == apply_func(F, [X]).

comp_with_math(F, X, Y) ->
    math:F(X, Y) == apply_func(F, [X, Y]).

%%------------------------------------------------------------------------------
%% Test cases for bits op
%%------------------------------------------------------------------------------

t_bits_op(_) ->
    ?PROPTEST(prop_bits_op).

prop_bits_op() ->
    ?FORALL({X, Y}, {integer(), integer()},
            begin
                (bnot X) == apply_func(bitnot, [X]) andalso
                (X band Y) == apply_func(bitand, [X, Y]) andalso
                (X bor Y) == apply_func(bitor, [X, Y]) andalso
                (X bxor Y) == apply_func(bitxor, [X, Y]) andalso
                (X bsl Y) == apply_func(bitsl, [X, Y]) andalso
                (X bsr Y) == apply_func(bitsr, [X, Y])
            end).

%%------------------------------------------------------------------------------
%% Test cases for string
%%------------------------------------------------------------------------------

t_lower_upper(_) ->
    ?assertEqual(<<"ABC4">>, apply_func(upper, [<<"abc4">>])),
    ?assertEqual(<<"0abc">>, apply_func(lower, [<<"0ABC">>])).

t_reverse(_) ->
    ?assertEqual(<<"dcba">>, apply_func(reverse, [<<"abcd">>])),
    ?assertEqual(<<"4321">>, apply_func(reverse, [<<"1234">>])).

t_strlen(_) ->
    ?assertEqual(4, apply_func(strlen, [<<"abcd">>])),
    ?assertEqual(2, apply_func(strlen, [<<"你好">>])).

t_substr(_) ->
    ?assertEqual(<<"">>, apply_func(substr, [<<"">>, 1])),
    ?assertEqual(<<"bc">>, apply_func(substr, [<<"abc">>, 1])),
    ?assertEqual(<<"bc">>, apply_func(substr, [<<"abcd">>, 1, 2])).

t_trim(_) ->
    ?assertEqual(<<>>, apply_func(trim, [<<>>])),
    ?assertEqual(<<>>, apply_func(ltrim, [<<>>])),
    ?assertEqual(<<>>, apply_func(rtrim, [<<>>])),
    ?assertEqual(<<"abc">>, apply_func(trim, [<<" abc ">>])),
    ?assertEqual(<<"abc ">>, apply_func(ltrim, [<<" abc ">>])),
    ?assertEqual(<<" abc">>, apply_func(rtrim, [<<" abc">>])).

ascii_string() -> list(range(0,127)).

bin(S) -> iolist_to_binary(S).

%%------------------------------------------------------------------------------
%% Test cases for array funcs
%%------------------------------------------------------------------------------

t_nth(_) ->
    ?assertEqual(2, lists:nth(2, [1,2,3,4])).

t_map_get(_) ->
    ?assertEqual(1, apply_func(map_get, [<<"a">>, #{a => 1}])),
    ?assertEqual(undefined, apply_func(map_get, [<<"a">>, #{}])),
    ?assertEqual(1, apply_func(map_get, [<<"a.b">>, #{a => #{b => 1}}])),
    ?assertEqual(undefined, apply_func(map_get, [<<"a.c">>, #{a => #{b => 1}}])).

t_map_put(_) ->
    ?assertEqual(#{a => 1}, apply_func(map_put, [<<"a">>, 1, #{}])),
    ?assertEqual(#{a => 2}, apply_func(map_put, [<<"a">>, 2, #{a => 1}])),
    ?assertEqual(#{a => #{b => 1}}, apply_func(map_put, [<<"a.b">>, 1, #{}])),
    ?assertEqual(#{a => #{b => 1, c => 1}}, apply_func(map_put, [<<"a.c">>, 1, #{a => #{b => 1}}])).

%%------------------------------------------------------------------------------
%% Test cases for Hash funcs
%%------------------------------------------------------------------------------

t_hash_funcs(_) ->
    ?PROPTEST(prop_hash_fun).

prop_hash_fun() ->
    ?FORALL(S, binary(),
            begin
                (32 == byte_size(apply_func(md5, [S]))) andalso
                (40 == byte_size(apply_func(sha, [S]))) andalso
                (64 == byte_size(apply_func(sha256, [S])))
            end).

%%------------------------------------------------------------------------------
%% Test cases for base64
%%------------------------------------------------------------------------------

t_base64_encode(_) ->
    ?PROPTEST(prop_base64_encode).

prop_base64_encode() ->
    ?FORALL(S, list(range(0, 255)),
            begin
                Bin = iolist_to_binary(S),
                Bin == base64:decode(apply_func(base64_encode, [Bin]))
            end).

%%------------------------------------------------------------------------------
%% Utility functions
%%------------------------------------------------------------------------------

apply_func(Name, Args) when is_atom(Name) ->
    erlang:apply(emqx_rule_funcs, Name, Args);
apply_func(Fun, Args) when is_function(Fun) ->
    erlang:apply(Fun, Args).

apply_func(Name, Args, Input) when is_map(Input) ->
    apply_func(apply_func(Name, Args), [Input]);
apply_func(Name, Args, Msg) ->
    apply_func(Name, Args, emqx_rule_runtime:columns(emqx_message:to_map(Msg))).

message() ->
    emqx_message:set_flags(#{dup => false},
        emqx_message:make(<<"clientid">>, 1, <<"topic/#">>, <<"payload">>)).

% t_contains_topic(_) ->
%     error('TODO').

% t_contains_topic_match(_) ->
%     error('TODO').

% t_div(_) ->
%     error('TODO').

% t_mod(_) ->
%     error('TODO').

% t_abs(_) ->
%     error('TODO').

% t_acos(_) ->
%     error('TODO').

% t_acosh(_) ->
%     error('TODO').

% t_asin(_) ->
%     error('TODO').

% t_asinh(_) ->
%     error('TODO').

% t_atan(_) ->
%     error('TODO').

% t_atanh(_) ->
%     error('TODO').

% t_ceil(_) ->
%     error('TODO').

% t_cos(_) ->
%     error('TODO').

% t_cosh(_) ->
%     error('TODO').

% t_exp(_) ->
%     error('TODO').

% t_floor(_) ->
%     error('TODO').

% t_fmod(_) ->
%     error('TODO').

% t_log(_) ->
%     error('TODO').

% t_log10(_) ->
%     error('TODO').

% t_log2(_) ->
%     error('TODO').

% t_power(_) ->
%     error('TODO').

% t_round(_) ->
%     error('TODO').

% t_sin(_) ->
%     error('TODO').

% t_sinh(_) ->
%     error('TODO').

% t_sqrt(_) ->
%     error('TODO').

% t_tan(_) ->
%     error('TODO').

% t_tanh(_) ->
%     error('TODO').

% t_bitnot(_) ->
%     error('TODO').

% t_bitand(_) ->
%     error('TODO').

% t_bitor(_) ->
%     error('TODO').

% t_bitxor(_) ->
%     error('TODO').

% t_bitsl(_) ->
%     error('TODO').

% t_bitsr(_) ->
%     error('TODO').

% t_lower(_) ->
%     error('TODO').

% t_ltrim(_) ->
%     error('TODO').

% t_rtrim(_) ->
%     error('TODO').

% t_upper(_) ->
%     error('TODO').

% t_split(_) ->
%     error('TODO').

% t_md5(_) ->
%     error('TODO').

% t_sha(_) ->
%     error('TODO').

% t_sha256(_) ->
%     error('TODO').

% t_json_encode(_) ->
%     error('TODO').

% t_json_decode(_) ->
%     error('TODO').


%%------------------------------------------------------------------------------
%% CT functions
%%------------------------------------------------------------------------------

all() ->
    IsTestCase = fun("t_" ++ _) -> true; (_) -> false end,
    [F || {F, _A} <- module_info(exports), IsTestCase(atom_to_list(F))].

suite() ->
    [{ct_hooks, [cth_surefire]}, {timetrap, {seconds, 30}}].

