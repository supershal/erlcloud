%% -*- mode: erlang;erlang-indent-level: 4;indent-tabs-mode: nil -*-
-module(erlcloud_ddb_tests).
-include_lib("eunit/include/eunit.hrl").
-include("erlcloud.hrl").

%% Unit tests for ddb.
%% These tests work by using meck to mock httpc. There are two classes of test: input and output.
%%
%% Input tests verify that different function args produce the desired JSON request.
%% An input test list provides a list of funs and the JSON that is expected to result.
%%
%% Output tests verify that the http response produces the correct return from the fun.
%% An output test lists provides a list of response bodies and the expected return.

%% The _ddb_test macro provides line number annotation to a test, similar to _test, but doesn't wrap in a fun
-define(_ddb_test(T), {?LINE, T}).
%% The _f macro is a terse way to wrap code in a fun. Similar to _test but doesn't annotate with a line number
-define(_f(F), fun() -> F end).
                            
%%%===================================================================
%%% Test entry points
%%%===================================================================

operation_test_() ->
    {foreach,
     fun start/0,
     fun stop/1,
     [fun error_handling_tests/1,
      fun delete_item_input_tests/1,
      fun delete_item_output_tests/1,
      fun get_item_input_tests/1,
      fun get_item_output_tests/1,
      fun put_item_input_tests/1,
      fun put_item_output_tests/1,
      fun update_item_input_tests/1,
      fun update_item_output_tests/1]}.

start() ->
    meck:new(httpc, [unstick]),
    ok.

stop(_) ->
    meck:unload(httpc).

%%%===================================================================
%%% Input test helpers
%%%===================================================================

-type expected_body() :: string().

%% verifies that the parameters in the body match the expected parameters
-spec validate_body(binary(), expected_body()) -> ok.
validate_body(Body, Expected) ->
    Want = jsx:decode(list_to_binary(Expected)), 
    Actual = jsx:decode(Body),
    case Want =:= Actual of
        true -> ok;
        false ->
            ?debugFmt("~nEXPECTED~n~p~nACTUAL~n~p~n", [Want, Actual])
    end,
    ?assertEqual(Want, Actual).

%% returns the mock of the httpc function input tests expect to be called.
%% Validates the request body and responds with the provided response.
-spec input_expect(string(), expected_body()) -> fun().
input_expect(Response, Expected) ->
    fun(post, {_Url, _Headers, _ContentType, Body}, [], _Opts) -> 
            validate_body(Body, Expected),
            {ok, {{0, 200, 0}, 0, list_to_binary(Response)}} 
    end.

%% input_test converts an input_test specifier into an eunit test generator
-type input_test_spec() :: {pos_integer(), {fun(), expected_body()} | {string(), fun(), expected_body()}}.
-spec input_test(string(), input_test_spec()) -> tuple().
input_test(Response, {Line, {Description, Fun, Expected}}) when
      is_list(Description) ->
    {Description, 
     {Line,
      fun() ->
              meck:expect(httpc, request, input_expect(Response, Expected)),
              erlcloud_ddb:configure(string:copies("A", 20), string:copies("a", 40)),
              Fun()
      end}}.
%% input_test(Response, {Line, {Fun, Params}}) ->
%%     input_test(Response, {Line, {"", Fun, Params}}).

%% input_tests converts a list of input_test specifiers into an eunit test generator
-spec input_tests(string(), [input_test_spec()]) -> [tuple()].
input_tests(Response, Tests) ->
    [input_test(Response, Test) || Test <- Tests].

%%%===================================================================
%%% Output test helpers
%%%===================================================================

%% returns the mock of the httpc function output tests expect to be called.
-spec output_expect(string()) -> fun().
output_expect(Response) ->
    fun(post, {_Url, _Headers, _ContentType, _Body}, [], _Opts) -> 
            {ok, {{0, 200, 0}, 0, list_to_binary(Response)}} 
    end.

%% output_test converts an output_test specifier into an eunit test generator
-type output_test_spec() :: {pos_integer(), {string(), term()} | {string(), string(), term()}}.
-spec output_test(fun(), output_test_spec()) -> tuple().
output_test(Fun, {Line, {Description, Response, Result}}) ->
    {Description,
     {Line,
      fun() ->
              meck:expect(httpc, request, output_expect(Response)),
              erlcloud_ddb:configure(string:copies("A", 20), string:copies("a", 40)),
              Actual = Fun(),
              ?assertEqual(Result, Actual)
      end}}.
%% output_test(Fun, {Line, {Response, Result}}) ->
%%     output_test(Fun, {Line, {"", Response, Result}}).
      
%% output_tests converts a list of output_test specifiers into an eunit test generator
-spec output_tests(fun(), [output_test_spec()]) -> [term()].       
output_tests(Fun, Tests) ->
    [output_test(Fun, Test) || Test <- Tests].


%%%===================================================================
%%% Error test helpers
%%%===================================================================

-spec httpc_response(pos_integer(), string()) -> tuple().
httpc_response(Code, Body) ->
    {ok, {{"", Code, ""}, [], list_to_binary(Body)}}.
    
-type error_test_spec() :: {pos_integer(), {string(), list(), term()}}.
-spec error_test(fun(), error_test_spec()) -> tuple().
error_test(Fun, {Line, {Description, Responses, Result}}) ->
    %% Add a bogus response to the end of the request to make sure we don't call too many times
    Responses1 = Responses ++ [httpc_response(200, "TOO MANY REQUESTS")],
    {Description,
     {Line,
      fun() ->
              meck:sequence(httpc, request, 4, Responses1),
              erlcloud_ddb:configure(string:copies("A", 20), string:copies("a", 40)),
              Actual = Fun(),
              ?assertEqual(Result, Actual)
      end}}.
      
-spec error_tests(fun(), [error_test_spec()]) -> [term()].
error_tests(Fun, Tests) ->
    [error_test(Fun, Test) || Test <- Tests].

%%%===================================================================
%%% Actual test specifiers
%%%===================================================================

%% Error handling tests based on:
%% http://docs.aws.amazon.com/amazondynamodb/latest/developerguide/ErrorHandling.html
error_handling_tests(_) ->
    OkResponse = httpc_response(200, "
{\"Item\":
	{\"friends\":{\"SS\":[\"Lynda\", \"Aaron\"]},
	 \"status\":{\"S\":\"online\"}
	},
\"ConsumedCapacityUnits\": 1
}"                                   
                                  ),
    OkResult = {ok, [{<<"friends">>, [<<"Lynda">>, <<"Aaron">>]},
                     {<<"status">>, <<"online">>}]},

    Tests = 
        [?_ddb_test(
            {"Test retry after ProvisionedThroughputExceededException",
             [httpc_response(400, "
{\"__type\":\"com.amazonaws.dynamodb.v20111205#ProvisionedThroughputExceededException\",
\"message\":\"The level of configured provisioned throughput for the table was exceeded. Consider increasing your provisioning level with the UpdateTable API\"}"
                            ),
              OkResponse],
             OkResult}),
         ?_ddb_test(
            {"Test ConditionalCheckFailed error",
             [httpc_response(400, "
{\"__type\":\"com.amazonaws.dynamodb.v20111205#ConditionalCheckFailedException\",
\"message\":\"The expected value did not match what was stored in the system.\"}"
                            )],
             {error, <<"ConditionalCheckFailedException">>}}),
         ?_ddb_test(
            {"Test retry after 500",
             [httpc_response(500, ""),
              OkResponse],
             OkResult})
        ],
    
    error_tests(?_f(erlcloud_ddb:get_item(<<"table">>, <<"key">>)), Tests).


%% DeleteItem test based on the API examples:
%% http://docs.aws.amazon.com/amazondynamodb/latest/developerguide/API_DeleteItem.html
delete_item_input_tests(_) ->
    Tests =
        [?_ddb_test(
            {"DeleteItem example request",
             ?_f(erlcloud_ddb:delete_item(<<"comp-table">>, {"Mingus", 200},
                                          [{expected, {<<"status">>, "shopping"}},
                                           {return_values, all_old}])), "
{\"TableName\":\"comp-table\",
    \"Key\":
        {\"HashKeyElement\":{\"S\":\"Mingus\"},\"RangeKeyElement\":{\"N\":\"200\"}},
    \"Expected\":
        {\"status\":{\"Value\":{\"S\":\"shopping\"}}},
    \"ReturnValues\":\"ALL_OLD\"
}"
            })
        ],

    Response = "
{\"Attributes\":
    {\"friends\":{\"SS\":[\"Dooley\",\"Ben\",\"Daisy\"]},
    \"status\":{\"S\":\"shopping\"},
    \"time\":{\"N\":\"200\"},
    \"user\":{\"S\":\"Mingus\"}
    },
\"ConsumedCapacityUnits\":1
}",
    input_tests(Response, Tests).

delete_item_output_tests(_) ->
    Tests = 
        [?_ddb_test(
            {"DeleteItem example response", "
{\"Attributes\":
    {\"friends\":{\"SS\":[\"Dooley\",\"Ben\",\"Daisy\"]},
    \"status\":{\"S\":\"shopping\"},
    \"time\":{\"N\":\"200\"},
    \"user\":{\"S\":\"Mingus\"}
    },
\"ConsumedCapacityUnits\":1
}",
             {ok, [{<<"friends">>, [<<"Dooley">>, <<"Ben">>, <<"Daisy">>]},
                   {<<"status">>, <<"shopping">>},
                   {<<"time">>, 200},
                   {<<"user">>, <<"Mingus">>}]}})
        ],
    
    output_tests(?_f(erlcloud_ddb:delete_item(<<"table">>, <<"key">>)), Tests).

%% GetItem test based on the API examples:
%% http://docs.aws.amazon.com/amazondynamodb/latest/developerguide/API_GetItem.html
get_item_input_tests(_) ->
    Example1Response = "
{\"TableName\":\"comptable\",
	\"Key\":
		{\"HashKeyElement\":{\"S\":\"Julie\"},
		\"RangeKeyElement\":{\"N\":\"1307654345\"}},
	\"AttributesToGet\":[\"status\",\"friends\"],
	\"ConsistentRead\":true
}",

    Tests =
        [?_ddb_test(
            {"GetItem example request, with fully specified keys",
             ?_f(erlcloud_ddb:get_item(<<"comptable">>, {{s, <<"Julie">>}, {n, 1307654345}}, 
                                       [{attributes_to_get, [<<"status">>, <<"friends">>]},
                                        {consistent_read, true}])),
             Example1Response}),
         ?_ddb_test(
            {"GetItem example request, with inferred key types",
             ?_f(erlcloud_ddb:get_item(<<"comptable">>, {"Julie", 1307654345}, 
                                       [{attributes_to_get, [<<"status">>, <<"friends">>]},
                                        {consistent_read, true}])),
             Example1Response}),
         ?_ddb_test(
            {"GetItem Simple call with only hash key and no options",
             ?_f(erlcloud_ddb:get_item(<<"comptable">>, {s, "Julie"})), "
{\"TableName\":\"comptable\",
	\"Key\":
		{\"HashKeyElement\":{\"S\":\"Julie\"}}
}"
             })
        ],

    Response = "
{\"Item\":
	{\"friends\":{\"SS\":[\"Lynda, Aaron\"]},
	\"status\":{\"S\":\"online\"}
	},
\"ConsumedCapacityUnits\": 1
}",
    input_tests(Response, Tests).

get_item_output_tests(_) ->
    Tests = 
        [?_ddb_test(
            {"GetItem example response", "
{\"Item\":
	{\"friends\":{\"SS\":[\"Lynda\", \"Aaron\"]},
	 \"status\":{\"S\":\"online\"}
	},
\"ConsumedCapacityUnits\": 1
}",
             {ok, [{<<"friends">>, [<<"Lynda">>, <<"Aaron">>]},
                   {<<"status">>, <<"online">>}]}}),
         ?_ddb_test(
            {"GetItem test all attribute types", "
{\"Item\":
	{\"ss\":{\"SS\":[\"Lynda\", \"Aaron\"]},
	 \"ns\":{\"NS\":[\"12\",\"13\",\"14\"]},
	 \"bs\":{\"BS\":[\"BbY=\"]},
	 \"es\":{\"SS\":[]},
	 \"s\":{\"S\":\"Lynda\"},
	 \"n\":{\"N\":\"12\"},
	 \"b\":{\"B\":\"BbY=\"},
	 \"empty\":{\"S\":\"\"}
	},
\"ConsumedCapacityUnits\": 1
}",
             {ok, [{<<"ss">>, [<<"Lynda">>, <<"Aaron">>]},
                   {<<"ns">>, [12,13,14]},
                   {<<"bs">>, [<<5,182>>]},
                   {<<"es">>, []},
                   {<<"s">>, <<"Lynda">>},
                   {<<"n">>, 12},
                   {<<"b">>, <<5,182>>},
                   {<<"empty">>, <<>>}]}})
        ],
    
    output_tests(?_f(erlcloud_ddb:get_item(<<"table">>, <<"key">>)), Tests).

%% PutItem test based on the API examples:
%% http://docs.aws.amazon.com/amazondynamodb/latest/developerguide/API_PutItem.html
put_item_input_tests(_) ->
    Tests =
        [?_ddb_test(
            {"PutItem example request",
             ?_f(erlcloud_ddb:put_item(<<"comp5">>, 
                                       [{<<"time">>, 300}, 
                                        {<<"feeling">>, <<"not surprised">>},
                                        {<<"user">>, <<"Riley">>}],
                                       [{expected, {<<"feeling">>, <<"surprised">>}},
                                        {return_values, all_old}])), "
{\"TableName\":\"comp5\",
	\"Item\":
		{\"time\":{\"N\":\"300\"},
		\"feeling\":{\"S\":\"not surprised\"},
		\"user\":{\"S\":\"Riley\"}
		},
	\"Expected\":
		{\"feeling\":{\"Value\":{\"S\":\"surprised\"}}},
	\"ReturnValues\":\"ALL_OLD\"
}"
            })
        ],

    Response = "
{\"Attributes\":
	{\"feeling\":{\"S\":\"surprised\"},
	\"time\":{\"N\":\"300\"},
	\"user\":{\"S\":\"Riley\"}},
\"ConsumedCapacityUnits\":1
}",
    input_tests(Response, Tests).

put_item_output_tests(_) ->
    Tests = 
        [?_ddb_test(
            {"PutItem example response", "
{\"Attributes\":
	{\"feeling\":{\"S\":\"surprised\"},
	\"time\":{\"N\":\"300\"},
	\"user\":{\"S\":\"Riley\"}},
\"ConsumedCapacityUnits\":1
}",
             {ok, [{<<"feeling">>, <<"surprised">>},
                   {<<"time">>, 300},
                   {<<"user">>, <<"Riley">>}]}})
        ],
    
    output_tests(?_f(erlcloud_ddb:put_item(<<"table">>, [])), Tests).

%% UpdateItem test based on the API examples:
%% http://docs.aws.amazon.com/amazondynamodb/latest/developerguide/API_UpdateItem.html
update_item_input_tests(_) ->
    Tests =
        [?_ddb_test(
            {"UpdateItem example request",
             ?_f(erlcloud_ddb:update_item(<<"comp5">>, {"Julie", 1307654350},
                                          [{<<"status">>, <<"online">>, put}],
                                          [{expected, {<<"status">>, "offline"}},
                                           {return_values, all_new}])), "
{\"TableName\":\"comp5\",
    \"Key\":
        {\"HashKeyElement\":{\"S\":\"Julie\"},\"RangeKeyElement\":{\"N\":\"1307654350\"}},
    \"AttributeUpdates\":
        {\"status\":{\"Value\":{\"S\":\"online\"},
        \"Action\":\"PUT\"}},
    \"Expected\":{\"status\":{\"Value\":{\"S\":\"offline\"}}},
    \"ReturnValues\":\"ALL_NEW\"
}"
            }),
         ?_ddb_test(
            {"UpdateItem different update types",
             ?_f(erlcloud_ddb:update_item(<<"comp5">>, {"Julie", 1307654350},
                                          [{<<"number">>, 5, add},
                                           {<<"numberset">>, {ns, [3]}, add},
                                           {<<"todelete">>, delete},
                                           {<<"toremove">>, {ss, [<<"bye">>]}, delete},
                                           {<<"defaultput">>, <<"online">>}])), "
{\"TableName\":\"comp5\",
    \"Key\":
        {\"HashKeyElement\":{\"S\":\"Julie\"},\"RangeKeyElement\":{\"N\":\"1307654350\"}},
    \"AttributeUpdates\":
        {\"number\":{\"Value\":{\"N\":\"5\"}, \"Action\":\"ADD\"},
         \"numberset\":{\"Value\":{\"NS\":[\"3\"]}, \"Action\":\"ADD\"},
         \"todelete\":{\"Action\":\"DELETE\"},
         \"toremove\":{\"Value\":{\"SS\":[\"bye\"]}, \"Action\":\"DELETE\"},
         \"defaultput\":{\"Value\":{\"S\":\"online\"}}}
}"
            })

        ],

    Response = "
{\"Attributes\":
    {\"friends\":{\"SS\":[\"Lynda, Aaron\"]},
    \"status\":{\"S\":\"online\"},
    \"time\":{\"N\":\"1307654350\"},
    \"user\":{\"S\":\"Julie\"}},
\"ConsumedCapacityUnits\":1
}",
    input_tests(Response, Tests).

update_item_output_tests(_) ->
    Tests = 
        [?_ddb_test(
            {"UpdateItem example response", "
{\"Attributes\":
    {\"friends\":{\"SS\":[\"Lynda\", \"Aaron\"]},
    \"status\":{\"S\":\"online\"},
    \"time\":{\"N\":\"1307654350\"},
    \"user\":{\"S\":\"Julie\"}},
\"ConsumedCapacityUnits\":1
}",
             {ok, [{<<"friends">>, [<<"Lynda">>, <<"Aaron">>]},
                   {<<"status">>, <<"online">>},
                   {<<"time">>, 1307654350},
                   {<<"user">>, <<"Julie">>}]}})
        ],
    
    output_tests(?_f(erlcloud_ddb:update_item(<<"table">>, <<"key">>, [])), Tests).

