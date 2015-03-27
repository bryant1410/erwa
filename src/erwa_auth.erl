%%
%% Copyright (c) 2015 Bas Wegh
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in all
%% copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%% SOFTWARE.
%%

-module(erwa_auth).

-export([wamp_cra/2]).
-export([pbkdf2/4]).
-export([create_wampcra_challenge/4]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.


%% @doc calculates the cryptographic hash of the challenge by using the secret key.
-spec wamp_cra(Key :: binary(), Challenge :: binary() ) -> binary().
wamp_cra(Key,Challenge) ->
  Bin = crypto:hmac(sha256,Key,Challenge),
  base64:encode(Bin).


%% @doc calculates the derived key from secret key, using salt and iterations.
-spec pbkdf2(SecretKey :: binary(), Salt :: binary(),
                      Iterations :: non_neg_integer(),
                      Length :: non_neg_integer()) -> {ok, NewKey :: binary()}.
pbkdf2(SecretKey, Salt, Iterations, Length) ->
  pbkdf2:pbkdf2(SecretKey, Salt, Iterations, Length).


-spec create_wampcra_challenge(AuthProvider :: binary(), AuthId :: binary(), Authrole :: binary(), Session :: non_neg_integer() ) -> {ok,Challenge :: binary(), calendar:timestamp() }.
create_wampcra_challenge(AuthProvider, AuthId, Authrole, Session) ->
  Now = erlang:now(),
  {{Year,Month,Day},{Hour,Minute,Seconds}} = calendar:now_to_universal_time(Now),
  Timestamp = list_to_binary(io_lib:format("~.10B-~2.10.0B-~2.10.0BT~2.10.0B:~2.10.0B:~2.10.0B.000Z",[Year,Month,Day,Hour,Minute,Seconds])),
  Challenge = jsx:encode([{<<"nonce">>,nonce()},{<<"authprovider">>,AuthProvider},
                          {<<"authid">>,AuthId},{<<"timestamp">>,Timestamp},
                          {<<"authrole">>,Authrole},{<<"authmethod">>,<<"wampcra">>},
                          {<<"session">>,Session}]),
  {ok, Challenge, Now }.

nonce() ->
  base64:encode(crypto:strong_rand_bytes(15)).


-ifdef(TEST).

wamp_cra_test() ->
  Challenge = <<"{\"nonce\": \"LHRTC9zeOIrt_9U3\", \"authprovider\": \"userdb\", \"authid\": \"peter\",\"timestamp\": \"2015-01-29T20:36:25.448Z\", \"authrole\": \"user\",\"authmethod\": \"wampcra\", \"session\": 3251278072152162}">>,
  Key = <<"secret1">>,
  Signature = <<"/h8nclt5hisNxpVobobQR7f8nL1IAZhsllT014mo/xg=">>,
  Signature = wamp_cra(Key, Challenge),
  ok.

-endif.
