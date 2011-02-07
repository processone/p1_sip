%%%-------------------------------------------------------------------
%%% File    : esip_udp.erl
%%% Author  : Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% Description : Handle UDP sockets
%%%
%%% Created : 14 Jul 2009 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(esip_udp).

-behaviour(gen_server).

%% API
-export([start_link/3, start/3, start/2, stop/0, send/3, connect/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("esip.hrl").
-include("esip_lib.hrl").

-record(state, {sock, ip, port}).

%%====================================================================
%% API
%%====================================================================
start_link(IP, Port, Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [IP, Port, Opts], []).

start(IP, Port, Opts) ->
    ChildSpec =	{?MODULE,
		 {?MODULE, start_link, [IP, Port, Opts]},
		 transient, 2000, worker,
		 [?MODULE]},
    supervisor:start_child(esip_sup, ChildSpec).

start(Port, Opts) ->
    gen_server:start(?MODULE, [Port, Opts], []).

stop() ->
    gen_server:call(?MODULE, stop),
    supervisor:delete_child(esip_sup, ?MODULE).

send(Sock, {Addr, Port}, Data) ->
    gen_udp:send(Sock, Addr, Port, Data).

connect([AddrPort|_Addrs], Pid) ->
    case catch gen_server:call(Pid, get_socket) of
        {ok, Sock} ->
            {ok, Sock#sip_socket{peer = AddrPort}};
        {'EXIT', Reason} = Err ->
            ?ERROR_MSG("failed to get UDP socket: ~p", [Err]),
            case Reason of
                {timeout, _} ->
                    {error, timeout};
                _ ->
                    {error, internal_server_error}
            end;
        Res ->
            Res
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([Port, Opts]) ->
    case gen_udp:open(Port, [binary,
			     {active, once} | Opts]) of
	{ok, S} ->
            case inet:sockname(S) of
                {ok, {IP, _}} ->
                    esip_transport:register_udp_listener(self()),
                    {ok, #state{sock = S, ip = IP, port = Port}};
                {error, Reason} ->
                    {stop, Reason}
            end;
	{error, Reason} ->
            {stop, Reason}
    end.

handle_call(get_socket, _From, State) ->
    SIPSock = #sip_socket{type = udp, sock = State#state.sock,
                          addr = {State#state.ip, State#state.port}},
    {reply, {ok, SIPSock}, State};
handle_call(stop, _From, State) ->
    {stop, normal, State};
handle_call(_Request, _From, State) ->
    {reply, bad_request, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({udp, S, IP, Port, Data}, #state{sock = S} = State) ->
    MyAddr = {State#state.ip, State#state.port},
    SIPSock = #sip_socket{type = udp, sock = S,
                          addr = MyAddr, peer = {IP, Port}},
    esip:callback(data_in, [udp, {IP, Port}, MyAddr, Data]),
    transport_recv(SIPSock, Data),
    inet:setopts(S, [{active, once}]),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{sock = S}) ->
    catch gen_udp:close(S),
    esip_transport:unregister_udp_listener(self()),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------
transport_recv(SIPSock, Data) ->
    case catch esip_codec:decode(Data) of
        {ok, Msg} ->
            case catch esip_transport:recv(SIPSock, Msg) of
                {'EXIT', Reason} ->
                    ?ERROR_MSG("transport layer failed:~n"
                               "** Packet: ~p~n** Reason: ~p",
                               [Msg, Reason]);
                _ ->
                    ok
            end;
	Err ->
	    Err
    end.
