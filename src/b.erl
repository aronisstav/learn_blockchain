%% -*- erlang-indent-level: 4 -*-

%%% @doc Implements data structure for a simple single-node blockchain
%%% TODO: Balances can be negative, add check
%%% TODO: Allow storing arbitrary values not just #transaction{} in block
%%% @end

-module(b).

%% An account address on the blockchain, can be any binary string
-type address() :: binary().
-type hash() :: binary().

%% An example transaction
-record(transaction, {
    from :: address(),
    to :: address(),
    amount :: integer()  % use tiniest bits as smallest unit. Let's say cents
}).
-type transaction() :: #transaction{}.

%% Block header is stored together with a block. Genesis block is a special
%% block which has 0 as parent hash.
-record(block_header, {
    miner :: address(),
    hash :: hash(),
    parent_hash :: hash()
}).
-type block_header() :: #block_header{}.


%% Block is a list of transactions, just that
-record(block, {
    entries :: list(transaction())
}).
-type block() :: #block{}.


%% API
-export([
    add/1,
    balances/0,
    close/0,
    make_genesis/0,
    open/0
]).


-define(DETS_BLOCKS, dets_blocks).
-define(DETS_HEADERS, dets_headers).
-define(SELF_ADDRESS, <<"local-test-miner">>).
-define(MINT, <<"1">>).


open() ->
    {ok, _} = dets:open_file(?DETS_HEADERS,
                             [{file, "headers.dets"},
                              {auto_save, 250}]),
    {ok, _} = dets:open_file(?DETS_BLOCKS,
                             [{file, "blocks.dets"},
                              {auto_save, 250}]),
    case get_last_blockheader() of
        undefined ->
            %% No blocks yet, create a first genesis block with 0 hash
            {H, B} = make_genesis(),
            dets:insert(?DETS_BLOCKS, {<<0:160>>, B}),
            dets:insert(?DETS_HEADERS, {0, H});

        {ok, {_N, #block_header{}}} ->
            ok
    end.


close() ->
    dets:close(?DETS_HEADERS),
    dets:close(?DETS_BLOCKS).


-spec get_last_blockheader() -> {ok, {integer(), block_header()}} | undefined.
get_last_blockheader() ->
    N = dets:info(?DETS_HEADERS, size),
    case N of
        0 -> undefined;
        _ ->
            [LastH] = dets:lookup(?DETS_HEADERS, N - 1),
            {ok, LastH}
    end.


%% @doc Create a pair {header(), block()} for first genesis entry.
make_genesis() ->
    Block = #block{entries = []},
    Header = #block_header{
        miner       = <<>>,
        hash        = <<0:160>>,
        parent_hash = <<0:160>>
    },
    {Header, Block}.


%% @doc Add another block with a list of entries
-spec add(list(transaction())) -> {integer(), block_header()} | 'rejected'.
add(Entries) ->
    case valid(Entries, balances()) of
        true -> attach(Entries);
        false -> rejected
    end.

valid([], _) -> true;
valid([Transaction|Rest], Balances) ->
    #transaction{
       from = From,
       to = To,
       amount = Amount
      } = Transaction,
    FromBalance = maps:get(From, Balances, 0),
    Valid =
        case From =:= ?MINT of
            true -> true;
            false -> FromBalance >= Amount
        end,
    case Valid of
        false -> false;
        true ->
            Acc = Balances,
            Acc1 =
                maps:update_with(
                  From,
                  fun(B) -> B - Amount end,
                  -Amount,
                  Acc),
            NewBalances =
                maps:update_with(
                  To,
                  fun(B) -> B + Amount end,
                  Amount,
                  Acc1),
            valid(Rest, NewBalances)
    end.

attach(Entries) ->
    {ok, {N, #block_header{hash = PrevHash}}} = get_last_blockheader(),
    Block = #block{entries = Entries},
    Header0 = #block_header{
        miner       = ?SELF_ADDRESS,
        hash        = <<>>,
        parent_hash = PrevHash
    },
    BlockHash = get_block_hash(Block, Header0),
    Header = Header0#block_header{hash = BlockHash},

    dets:insert(?DETS_BLOCKS, {BlockHash, Block}),
    dets:insert(?DETS_HEADERS, {N + 1, Header}),
    {N + 1, Header}.

%% @private
%% @doc Get hash of a block + block header with empty hash (will be set after
%% calculating this hash)
get_block_hash(Block, BlockHeader) ->
    crypto:hash(sha, term_to_binary({Block, BlockHeader})).


%% @doc For each block header from 0 to (last), read the entries and accumulate
%% the available balances.
balances() ->
    EntriesFn =
        fun(#transaction{from   = From,
                         to     = To,
                         amount = Amount}, Acc) ->
            Acc1 = maps:update_with(From,
                                    fun(B) -> B - Amount end,
                                    -Amount,
                                    Acc),
            maps:update_with(To,
                             fun(B) -> B + Amount end,
                             Amount,
                             Acc1)
        end,
    BlockCount = dets:info(?DETS_HEADERS, size),
    lists:foldl(
        fun(N, Acc) ->
            [{_, #block_header{hash = Hash}}] = dets:lookup(?DETS_HEADERS, N),
            [{_, #block{entries = Entries}}] = dets:lookup(?DETS_BLOCKS, Hash),
            lists:foldl(EntriesFn, Acc, Entries)
        end,
        #{},
        lists:seq(0, BlockCount - 1)
    ).
