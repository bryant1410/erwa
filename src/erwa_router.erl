%%
%% Copyright (c) 2014 Bas Wegh
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

%% @private
-module(erwa_router).
-behaviour(gen_server).



-export([shutdown/1]).

-export([remove_session/2]).

-export([handle_wamp/2]).

%% API.
-export([start/1]).
-export([start_link/1]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).



shutdown(Router) ->
  gen_server:call(Router,shutdown).

remove_session(Router,Reason) ->
  gen_server:call(Router,{remove_session,Reason}).

handle_wamp(Router,Msg) ->
  gen_server:call(Router,{handle_wamp,Msg}).

start(Args) ->
  gen_server:start(?MODULE, [Args], []).

start_link(Args) ->
  gen_server:start_link(?MODULE, [Args], []).


-define(ROUTER_DETAILS,[{<<"roles">>,[{<<"broker">>,[{}]},{<<"dealer">>,[{}]}]}]).


-record(state, {
	realm = undefined,
  ets = undefined
}).

-record(session, {
  id = undefined,
  pid = undefined,
  monitor = undefined,
  details = undefined,
  requestId = 1,
  goodbye_sent = false,
  subscriptions = [],
  registrations = []
}).

-record(pid_session, {
  pid = undefined,
  session_id = undefined
}).

-record(monitor_session, {
  monitor = undefined,
  session_id = undefined
}).


-record(topic, {
  id = undefined,
  url = undefined,
  publishId = 1,
  subscribers = [],
  options = undefined
}).

-record(url_topic, {
  url = undefined,
  topic_id = undefined
  }).

%-record(subscription, {
%  id = undefined,
%  topicId = undefined,
%  options = undefined}).

-record(procedure, {
  id = undefined,
  url = undefined,
  options = undefined,
  session_id = undefined
}).

-record(url_procedure, {
  url = undefined,
  procedure_id = undefined
}).

-record(invocation, {
  id = undefined,
  timestamp = undefined,
  callee_id = undefined,
  ref = undefined,
  procedure_id = undefined,
  request_id = undefined,
  caller_id = undefined,
  caller_pid = undefined,
  options = undefined,
  arguments = undefined,
  argumentskw = undefined
}).

%% gen_server.

-define(TABLE_ACCESS,protected).

-spec init(Params :: list() ) -> {ok,#state{}}.
init([Realm]) ->
  Ets = ets:new(erwa_router,[?TABLE_ACCESS,set,{keypos,2}]),
  {ok,#state{realm=Realm,ets=Ets}}.


handle_call({handle_wamp,Msg},{Pid,_Ref},State) ->
  try handle_wamp_message(Msg,Pid,State) of
    ok -> {reply,ok,State};
    Result -> {reply,{error,unknown_result,Result},State}
  catch
    Error:Reason -> {reply,{error,Error,Reason},State}
  end;
handle_call(shutdown, _From, State) ->
  {stop, normal, State};
handle_call(_Msg,_From,State) ->
   {reply,shutdown,State}.

handle_cast(_Request, State) ->
	{noreply, State}.

handle_info({'DOWN',Ref,process,_Pid,_Reason},State) ->
  remove_session_with_ref(Ref,State),
  {noreply,State};
handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.




-spec handle_wamp_message(Msg :: term(),Pid :: pid(), State :: #state{}) -> ok.
handle_wamp_message({hello,Realm,Details},Pid,#state{realm=Realm}=State) ->
  {ok,SessionId} = create_session(Pid,Details,State),
  send_message_to(Pid,{welcome,SessionId,?ROUTER_DETAILS});

handle_wamp_message({goodbye,Details,_Reason},Pid,#state{ets=Ets}=State) ->
  Session = get_session_from_pid(Pid,State),
  SessionId = Session#session.id,
  case Session#session.goodbye_sent of
    true ->
      send_message_to({shutdown},Pid);
    _ ->
      ets:update_element(Ets,SessionId,{#session.goodbye_sent,true}),
      send_message_to({goodbye,[{}],goodbye_and_out},SessionId)

  end;

handle_wamp_message({publish,RequestId,Options,Topic,Arguments,ArgumentsKw},Pid,State) ->
  {ok,PublicationId} = send_event_to_topic(Pid,Options,Topic,Arguments,ArgumentsKw,State),
  % TODO: send a reply if asked for ...
  ok;

handle_wamp_message({subscribe,RequestId,Options,Topic},Pid,State) ->
  {ok,TopicId} = subscribe_to_topic(Pid,Options,Topic,State),
  send_message_to({subscribed,RequestId,TopicId},Pid);

handle_wamp_message({unsubscribe,RequestId,SubscriptionId},Pid,State) ->
  case unsubscribe_from_topic(Pid,SubscriptionId,State) of
    true ->
      send_message_to({unsubscribed,RequestId},Pid);
    false ->
      send_message_to({error,unsubscribe,RequestId,[{}],no_such_subscription},Pid)
  end;

handle_wamp_message({call,RequestId,Options,Procedure,Arguments,ArgumentsKw},Pid,State) ->
  case enqueue_procedure_call( Pid, RequestId, Options,Procedure,Arguments,ArgumentsKw,State) of
    true ->
      ok;
    false ->
      send_message_to({error,call,RequestId,[{}],no_such_procedure},Pid)
  end;

handle_wamp_message({register,RequestId,Options,Procedure},Pid,State) ->
  case register_procedure(Pid,Options,Procedure,State) of
    {ok,RegistrationId} ->
      send_message_to({registered,RequestId,RegistrationId},Pid);
    {error,procedure_already_exists} ->
      send_message_to({register,error,RequestId,[{}],procedure_already_exists},Pid)
  end;

handle_wamp_message({unregister,RequestId,RegistrationId},Pid,State) ->
  case unregister_procedure(Pid,RegistrationId,State) of
    true ->
      send_message_to({unregistered,RequestId},Pid);
    false ->
      send_message_to({error,unregister,RequestId,[{}],no_such_registration},Pid)
  end;

handle_wamp_message({error,invocation,_InvocationId,_Details,_Error,_Arguments,_ArgumentsKw},_Pid,_State) ->
  % TODO: implement
  ok;
handle_wamp_message({yield,_InvocationId,_Options,_Arguments,_ArgumentsKw},_Pid,_State) ->
  % TODO: implement
  ok;
handle_wamp_message(Msg,_Pid,_State) ->
  io:format("unknown message ~p~n",[Msg]),
  ok.


-spec create_session(Pid :: pid(), Details :: list(), State :: #state{}) -> {ok,non_neg_integer()}.
create_session(Pid,Details,#state{ets=Ets}=State) ->
  Id = gen_id(),
  MonRef = monitor(process,Pid),
  case ets:insert_new(Ets,[#session{id=Id,pid=Pid,details=Details,monitor=MonRef},
                                #monitor_session{monitor=MonRef,session_id=Id},
                                #pid_session{pid=Pid,session_id=Id}]) of
    true ->
      {ok,Id};
    _ ->
      demonitor(MonRef),
      create_session(Pid,Details,State)
  end.

-spec send_event_to_topic(FromPid :: pid(), Options :: list(), Url :: binary(), Arguments :: list()|undefined, ArgumentsKw :: list()|undefined, State :: #state{} ) -> {ok,non_neg_integer()}.
send_event_to_topic(FromPid,_Options,Url,Arguments,ArgumentsKw,#state{ets=Ets}) ->
  PublicationId =
    case ets:lookup(Ets,Url) of
      [] ->
        gen_id();
      [UrlTopic] ->
        TopicId = UrlTopic#url_topic.topic_id,
        [Topic] = ets:lookup(Ets,TopicId),
        IdToPid = fun(Id,Pids) -> [#session{pid=Pid}] = ets:lookup(Ets,Id), [Pid|Pids] end,
        Peers = lists:delete(FromPid,lists:foldl(IdToPid,[],Topic#topic.subscribers)),
        SubscriptionId = Topic#topic.id,
        PublishId = gen_id(),
        Details = [{}],
        Message = {event,SubscriptionId,PublishId,Details,Arguments,ArgumentsKw},
        send_message_to(Message,Peers),
        PublishId
    end,
  {ok,PublicationId}.

-spec subscribe_to_topic(Pid :: pid(), Options :: list(), Url :: binary(), State :: #state{}) -> {ok, non_neg_integer()}.
subscribe_to_topic(Pid,Options,Url,#state{ets=Ets}=State) ->
  Session = get_session_from_pid(Pid,State),
  SessionId = Session#session.id,
  Subs = Session#session.subscriptions,
  Topic =
    case ets:lookup(Ets,Url) of
      [] ->
        % create the topic ...
        {ok,T} = create_topic(Url,Options,State),
        T;
      [UrlTopic] ->
        Id = UrlTopic#url_topic.topic_id,
        [T] = ets:lookup(Ets,Id),
        T
    end,
  #topic{id=TopicId,subscribers=Subscribers} = Topic,
  ets:update_element(Ets,TopicId,{#topic.subscribers,[SessionId|lists:delete(SessionId,Subscribers)]}),
  ets:update_element(Ets,SessionId,{#session.subscriptions,[TopicId|lists:delete(TopicId,Subs)]}),
  {ok,TopicId}.


-spec create_topic(Url :: binary(), Options :: list, State :: #state{}) -> {ok,#topic{}}.
create_topic(Url,Options,#state{ets=Ets}=State) ->
  Id = gen_id(),
  T = #topic{id=Id,url=Url,options=Options},
  Topic =
    case ets:insert_new(Ets,T) of
      true ->
        true = ets:insert_new(Ets,#url_topic{url=Url,topic_id=Id}),
        T;
      false -> create_topic(Url,Options,State)
    end,
  {ok,Topic}.


-spec unsubscribe_from_topic(Pid :: pid(), SubscriptionId :: non_neg_integer(), State :: #state{}) -> true | false.
unsubscribe_from_topic(Pid,SubscriptionId,State) ->
  Session = get_session_from_pid(Pid,State),
  case lists:member(SubscriptionId,Session#session.subscriptions) of
    false ->
      false;

    true ->
      ok = remove_session_from_topic(Session,SubscriptionId,State),
      true
  end.





-spec register_procedure(Pid :: pid(), Options :: list(), ProcedureUrl :: binary(), State :: #state{}) -> {ok,non_neg_integer()} | {error,procedure_already_exists }.
register_procedure(Pid,Options,ProcedureUrl,#state{ets=Ets}=State) ->
  Session = get_session_from_pid(Pid,State),

  case ets:lookup(Ets,ProcedureUrl) of
    [] ->
      create_procedure(ProcedureUrl,Options,Session,State);
    _ ->
      {error,procedure_already_exists}
  end.


-spec unregister_procedure( Pid :: pid(), ProcedureId :: non_neg_integer(), State :: #state{}) -> true | false.
unregister_procedure(Pid,ProcedureId,State) ->
  Session = get_session_from_pid(Pid,State),
  case lists:member(ProcedureId,Session#session.registrations) of
    true ->
      ok = remove_session_from_procedure(Session,ProcedureId,State),
      true;
    false ->
      false
  end.


enqueue_procedure_call( Pid, RequestId, Options,ProcedureUrl,Arguments,ArgumentsKw,#state{ets=Ets}=State) ->
  Session = get_session_from_pid(Pid,State),
  %SessionId = Session#session.id,

  case ets:lookup(Ets,ProcedureUrl) of
    [] ->
      false;
    [#url_procedure{url=ProcedureUrl,procedure_id=ProcId}] ->
      [Procedure] = ets:lookup(Ets,ProcId),
      ProcedureId = Procedure#procedure.id,
      CalleeId = Procedure#procedure.session_id,
      [CalleeSession] = ets:lookup(Ets,CalleeId),
      CalleePid = CalleeSession#session.pid,

      Details = [{}],
      {ok,InvocationId} = create_invocation(Pid,Session,CalleeSession,RequestId,Procedure,Options,Arguments,ArgumentsKw,State),
      send_message_to({invocation,InvocationId,ProcedureId,Details,Arguments,ArgumentsKw},CalleePid),
      true
  end.

dequeue_procedure_call(Pid,Id,_Options,Arguments,ArgumentsKw,#state{ets=Ets}=State) ->
  Session = get_session_from_pid(Pid,State),
  SessionId = Session#session.id,
  case ets:lookup(Ets,Id) of
    [] -> {error,not_found};
    [Invocation] ->
      case Invocation#invocation.callee_id of
       SessionId ->
          #invocation{ref=From, request_id=RequestId} = Invocation,
          Details = [{}],
          %[Caller] = ets:lookup(Sessions,CallerId),
          %send_message_to_peers({result,RequestId,Details,Arguments,ArgumentsKw},[Caller#session.pid]),

          send_message_to({result,RequestId,Details,Arguments,ArgumentsKw},Pid),
          remove_invocation(Id,State),
          {ok};
        _ ->
          {error,wrong_session}
      end
  end.



-spec remove_session_with_ref(MonRef :: reference(), State :: #state{}) -> ok.
remove_session_with_ref(MonRef,#state{ets=Ets}=State) ->
  case ets:lookup(Ets,MonRef) of
    [RefSession] ->
      Id = RefSession#monitor_session.session_id,
      [Session] = ets:lookup(Ets,Id),
      remove_given_session(Session,State);
    [] ->
      ok
  end.


-spec remove_given_session(Session :: #session{}|undefined, State :: #state{}) -> ok.
remove_given_session(undefined,_) ->
  ok;
remove_given_session(Session,#state{ets=Ets}=State) ->
  Id = Session#session.id,
  MonRef = Session#session.monitor,
  RemoveTopic = fun(TopicId,Results) ->
        Result = remove_session_from_topic(Session,TopicId,State),
        [{TopicId,Result}|Results]
        end,
  _ResultTopics = lists:foldl(RemoveTopic,[],Session#session.subscriptions),

  RemoveRegistration = fun(RegistrationId,Results) ->
        Result = remove_session_from_procedure(Session,RegistrationId,State),
        [{RegistrationId,Result}|Results]
        end,
  _ResultRegistrations = lists:foldl(RemoveRegistration,[],Session#session.registrations),

  ets:delete(Ets,Id),
  ets:delete(Ets,MonRef),
  ets:delete(Ets,Session#session.pid),
  ok.


-spec remove_session_from_topic(Session :: #session{}, TopicId :: non_neg_integer(), State :: #state{}) -> ok | not_found.
remove_session_from_topic(Session,TopicId,#state{ets=Ets}) ->
  SessionId = Session#session.id,
  [Topic] = ets:lookup(Ets,TopicId),
  ets:update_element(Ets,TopicId,{#topic.subscribers,lists:delete(SessionId,Topic#topic.subscribers)}),
  ets:update_element(Ets,SessionId,{#session.subscriptions,lists:delete(TopicId,Session#session.subscriptions)}),
  ok.


-spec create_procedure(Url :: binary(), Options :: list(), Session :: #session{}, State :: #state{} ) -> {ok,non_neg_integer()}.
create_procedure(Url,Options,Session,#state{ets=Ets}=State) ->
  SessionId = Session#session.id,
  ProcedureId = gen_id(),
  case ets:insert_new(Ets,#procedure{id=ProcedureId,url=Url,session_id=SessionId,options=Options}) of
    true ->
      true = ets:insert_new(Ets,#url_procedure{url=Url,procedure_id=ProcedureId}),
      true = ets:update_element(Ets,SessionId,{#session.registrations, [ProcedureId| Session#session.registrations]}),
      {ok,ProcedureId};
    _ ->
      create_procedure(Url,Options,Session,State)
  end.

-spec remove_session_from_procedure( Session :: #session{}, ProcedureId :: non_neg_integer(), State :: #state{}) -> ok | not_found.
remove_session_from_procedure(Session,ProcedureId,#state{ets=Ets}) ->
  SessionId = Session#session.id,
  [Procedure] = ets:lookup(Ets,ProcedureId),
  ets:delete(Ets,ProcedureId),
  ets:delete(Ets,Procedure#procedure.url),
  ets:update_element(Ets,SessionId,{#session.registrations,lists:delete(ProcedureId,Session#session.registrations)}),
  ok.


-spec create_invocation(Pid :: pid(), Session :: #session{}, CalleeSession :: #session{}, RequestId :: non_neg_integer(), Procedure :: #procedure{}, Options :: list(), Arguments :: list(), ArgumentsKw :: list(), State :: #state{}) -> {ok, non_neg_integer()}.
create_invocation(Pid,Session,CalleeSession,RequestId,Procedure,Options,Arguments,ArgumentsKw,#state{ets=Ets}=State) ->
  Id = gen_id(),
  Invocation = #invocation{
        id = Id,
        timestamp = undefined,
        procedure_id = Procedure#procedure.id,
        request_id = RequestId,
        caller_id = Session#session.id,
        caller_pid = Pid,
        callee_id = CalleeSession#session.id,
        options = Options,
        arguments = Arguments,
        argumentskw = ArgumentsKw },
  case ets:insert_new(Ets,Invocation) of
    true ->
      {ok,Id};
    false ->
      create_invocation(Pid,Session,CalleeSession,RequestId,Procedure,Options,Arguments,ArgumentsKw,State)
  end.

-spec remove_invocation(Id :: non_neg_integer(), State :: #state{}) -> ok.
remove_invocation(InvocationId,#state{ets=Ets}) ->
  true = ets:delete(Ets,InvocationId),
  ok.


-spec send_message_to(Msg :: term(), Peer :: list() |  pid()) -> ok.
send_message_to(Msg,Pid) when is_pid(Pid) ->
  send_message_to(Msg,[Pid]);
send_message_to(Msg,Peers) when is_list(Peers) ->
  Send = fun(Pid) -> Pid ! {erwa,Msg} end,
  lists:foreach(Send,Peers),
  ok.


-spec get_session_from_pid(Pid :: pid(), State :: #state{}) -> #session{}|undefined.
get_session_from_pid(Pid,#state{ets=Ets}) ->
  case ets:lookup(Ets,Pid) of
    [PidSession] ->
        case ets:lookup(Ets,PidSession#pid_session.session_id) of
          [Session] -> Session;
          [] -> undefined
        end;
      [] -> undefined
  end.


-spec gen_id() -> non_neg_integer().
gen_id() ->
  crypto:rand_uniform(0,9007199254740993).



%% handle_call({hello,Realm,Details}, From, #state{realm=Realm}=State) ->
%%   handle_call({hello,Details}, From,State);
%% handle_call({hello,Details}, {Pid,_Ref}, #state{sess=Sess}=State) ->
%%    Reply =
%%     case ets:member(Sess,Pid) of
%%       true ->
%%         %hello from an already connected client -> shutdown (as specified)
%%         shutdown;
%%       false ->
%%         {ok,Id} = create_session(Pid,Details,State),
%%         {welcome,Id,?ROUTER_DETAILS}
%%     end,
  %% {reply,Reply,State};
%%
%% handle_call({goodbye,_Details,_Reason},{Pid,_Ref},#state{sess=Sess}=State) ->
  %% Session = get_session_from_pid(Pid,State),
  %% SessionId = Session#session.id,
  %% Reply =
    %% case Session#session.goodbye_sent of
      %% true -> shutdown;
      %% _ ->
%%         ets:update_element(Sess,SessionId,{#session.goodbye_sent,true}),
%%         %TODO: send a message after a timeout to close the session
%%         %send_message_to_peers({shutdown},[SessionId]),
%%         {goodbye,[{}],goodbye_and_out}
%%     end,
%%   {reply,Reply,State};
%%
%% handle_call({subscribe,RequestId,Options,TopicUrl}, {Pid,_Ref}, State) ->
%%   {ok,SubscriptionId} = subscribe_to_topic(Pid,Options,TopicUrl,State),
%%   {reply,{subscribed,RequestId,SubscriptionId},State};
%%
%% handle_call({unsubscribe,RequestId,SubscriptionId}, {Pid,_Ref} , State) ->
%%   Reply=
%%   case unsubscribe_from_topic(Pid,SubscriptionId,State) of
%%     {ok} -> {unsubscribed,RequestId};
%%     {error,Details,Reason} -> {error,unsubscribe,RequestId,Details,Reason}
%%   end,
%%   {reply,Reply,State};
%%
%% handle_call({publish,RequestId,Options,Url,Arguments,ArgumentsKw}, {Pid,_Ref}, State) ->
%%   {ok,PublicationId}= send_event_to_topic(Pid,Options,Url,Arguments,ArgumentsKw,State),
%%   Reply =
%%   case lists:member({acknowledge,true},Options) of
%%     true -> {published,RequestId,PublicationId};
%%     _ -> noreply
%%   end,
%%   {reply,Reply,State};
%%
%% handle_call({register,RequestId,Options,Procedure},{Pid,_Ref},State) ->
%%   Reply =
%%     case register_procedure(Pid,Options,Procedure,State) of
%%       {ok,RegistrationId} -> {registered,RequestId,RegistrationId};
%%       {error,Details,Reason} -> {error,register,RequestId,Details,Reason}
%%     end,
%%   {reply,Reply,State};
%%
%% handle_call({unregister,RequestId,RegistrationId},{Pid,_Ref},State) ->
%%   Reply =
%%     case unregister_procedure(Pid,RegistrationId,State) of
%%       {ok} -> {unregistered,RequestId};
%%       {error,Details,Reason} -> {error,unregister,RequestId,Details,Reason}
%%     end,
%%   {reply,Reply,State};
%%
%% handle_call({call,RequestId,Options,ProcedureUrl,Arguments,ArgumentsKw},{Pid,_Ref}=From,State) ->
%%   case enqueue_procedure_call(From,Pid,RequestId,Options,ProcedureUrl,Arguments,ArgumentsKw,State) of
%%     {ok} -> {noreply,State};
%%     {error,Details,Reason} -> {reply,{error,call,RequestId,Details,Reason,Arguments,ArgumentsKw},State}
%%   end;
%%
%% handle_call({yield,RequestId,Options,Arguments,ArgumentsKw},{Pid,_Ref},State) ->
%%   Reply =
%%     case dequeue_procedure_call(Pid,RequestId,Options,Arguments,ArgumentsKw,State) of
%%       {error,not_found} ->
%%         noreply;
%%       {ok} ->
%%         noreply;
%%       _ ->
%%         shutdown
%%       end,
%%   {reply,Reply,State};
%%
%% handle_call({remove_session,_Reason},{Pid,_Ref},State) ->
%%   Session = get_session_from_pid(Pid,State),
%%   remove_given_session(Session,State),
%%   {reply,shutdown,State};
%%
%% handle_call({handle_wamp,Msg},{_,Pid},State) ->
%%
%% handle_call(_Msg,_From,State) ->
%% {reply,shutdown,State}.





-ifdef(TEST).

hello_welcome_test() ->
  {ok,Pid} = start(<<"some.realm">>),
  {welcome,_,_} = hello(Pid,[]),
  shutdown = hello(Pid,[]).


 subscribe_test() ->
   {ok,Pid} = start(<<"some.realm">>),
   {welcome,_,_} = hello(Pid,[]),
   RequestId = crypto:rand_uniform(0,9007199254740993),
   {subscribed,RequestId,_SubscriptionId} = subscribe(Pid,RequestId,[],<<"does.not.exist">>).


resubscribe_test() ->
  {ok,Pid} = start(<<"some.realm">>),
  {welcome,_,_} = hello(Pid,[]),
  RequestId = crypto:rand_uniform(0,9007199254740993),
  {subscribed,RequestId,SubscriptionId} = subscribe(Pid,RequestId,[],<<"does.not.exist">>),
  {unsubscribed,RequestId} = unsubscribe(Pid,RequestId,SubscriptionId),
  {error,unsubscribe,RequestId,_Details,no_such_subscription} = unsubscribe(Pid,RequestId,SubscriptionId),
  RequestId2 = crypto:rand_uniform(0,9007199254740993),
  {subscribed,RequestId2,SubscriptionId} = subscribe(Pid,RequestId2,[],<<"does.not.exist">>).


register_test() ->
  {ok,Pid} = start(<<"some.realm">>),
  {welcome,_,_} = hello(Pid,<<"blah">>),
  RequestId = crypto:rand_uniform(0,9007199254740993),
  {registered,RequestId,_RegistrationId} = register(Pid,RequestId,[],<<"nice_fun">>).

unregister_test() ->
  {ok,Pid} = start(<<"some.realm">>),
  {welcome,_,_} = hello(Pid,<<"blah">>),
  RequestId = crypto:rand_uniform(0,9007199254740993),
  {registered,RequestId,RegistrationId} = register(Pid,RequestId,[],<<"nice_fun">>),
  {unregistered,RequestId} = unregister(Pid,RequestId,RegistrationId),
  {error,unregister,RequestId,_Details,no_such_registration} = unregister(Pid,RequestId,RegistrationId).


disconnect_test() ->
  {ok,Router} = start(<<"some.realm">>),
  TesterPid = self(),
  F = fun() ->
        {welcome,_,_} = hello(Router,<<"blah">>),
        RequestId = crypto:rand_uniform(0,9007199254740993),
        {registered,RequestId,_RegistrationId} = register(Router,RequestId,[],<<"nice_fun">>),
        TesterPid ! registered,
        receive
          go_on ->
            ok
        end
  end,
  ClientPid = spawn(F),
  receive
    registered ->
      ok
  end,

  ClientPid ! go_on,
  ok.



-endif.

