# Bright Falls RP Prediction Exchange

A RedM resource for VORP. Players use character cash to buy and sell outcome shares against other characters at bank counters. The exchange uses a red-and-black in-game interface.

## Install or update

1. For an existing install, keep your running resource folder name (for example, `bf_trades`) and copy the contents of the archive's `bf_markets` folder into it, including the entire `ui` folder. For a new install, place `bf_markets` in your server resources.
2. Keep OneSync enabled for server-side bank proximity checks. Start the resource after `vorp_core` with `ensure bf_trades` (or `ensure bf_markets` for the default folder). Restart the resource after updating.
3. Create or assign the VORP character job `trademanager` with your existing job tools. Any grade of that active job can open **Manage markets** from the bank UI. Market management now uses the active VORP job, so the former `bfmarkets.manage` ACE can be removed from server.cfg.
4. Visit the counter at Valentine, Rhodes, Blackwater or Saint Denis and press the displayed **R** key. The same locations are used by the client prompt and server validation. For custom bank interiors, adjust the locations, radius and key in `config.lua`.

## Trade a live market

Trade managers publish the question, two outcomes, a closing time and resolution rules. New markets start with an empty order book. Players choose an outcome, Buy or Sell, a limit price of 1–99 cents and a whole number of shares. The default buy order value range is $1–$500.

- A buy order reserves cash at its limit. A sell order reserves owned shares. A trade requires another character with a compatible order. Better prices execute first, then earlier orders at the same price. A fill executes at the resting order’s price. Any remaining quantity stays on the book.
- Opposite outcome buyers can fund a pair of shares for $1 together. Players can also sell to another buyer or close out complementary shares with another seller. Orders from the same character cannot match each other.
- The chart shows the most recent 180 executed prices for the first outcome, with local times and a 0–100¢ price axis. Quotes for the opposite outcome appear at their complementary price in the displayed book. The price chart, depth, position and volume refresh every two seconds while the exchange is open.
- For example, buying 100 shares at 40¢ costs $40. Selling all 100 at 65¢ earns $25. Holding all 100 through a winning resolution earns $60. Holding through a losing resolution loses the $40.
- Players can cancel unfilled quantity. Closing the market releases remaining reservations. Unspent cash, price improvements, sale proceeds and winnings can be collected with the market’s **Claim** button. Final trades cannot be refunded.
- At settlement, each winning share pays $1 and each losing share pays $0. Each buy order accepts at most 10,000 shares, limiting its maximum winning payout to $10,000 even when it fills in parts.
- Markets created before the order-book update continue under their original pooled wagering and payout rules. Their existing positions, claims and P&L use the same saved ledger.

## Settlement notifications

At settlement, participating characters see a short count from zero to their signed net result, including any earlier sale proceeds. Profit appears green and loss appears red. The overlay also works away from a bank, without taking game focus. Unseen results from this update are delivered at the next bank visit if the character was offline. Break-even results stay in Stats.

## Stats

The Stats button shows settled profit, loss, net result and open cash exposure (purchase costs less sale proceeds, floored at zero for each open market) for the active character. Settled results include claimable cash, and historical refunds contribute zero profit or loss. Recent results show the stake, payout and net for each market. The live market card also estimates P&L using the latest execution price. Actual exits depend on available orders. Older results are rolled into lifetime totals when pruned. History already pruned by a previous version cannot be reconstructed from this resource.

## Persistence and cash review

Market state uses server resource KVP. Include the server's resource KVP database and VORP database in your backups. Older fully paid markets are pruned as new markets are published.

VORP cash writes and the resource ledger use separate storage. The resource records a cash operation before calling VORP and checks the live character balance afterward. An interrupted or unverified payment can appear in **Manage markets** as a cash review. Verify the character's cash movement against your server logs and cash records before marking it applied or unapplied. The review records the result in the ledger without moving cash again. A full server crash can also occur after a live balance change and before VORP saves that balance. Reconcile VORP cash and the ledger after an unclean shutdown if your records show a discrepancy.

## Verification

A mocked VORP run exercised price and time priority, partial fills, resale, complementary orders, self-match prevention, share reservations, expiry on close, settlement, restart, claim handling and conservation of cash. A live RedM/OneSync test is still needed on the installed VORP version.

References:
- Default VORP bank locations: https://github.com/VORPCORE/vorp_banking/blob/main/config.lua
- VORP Core inventory cash calls: https://github.com/VORPCORE/vorp_inventory-v2
- Cfx Lua NUI callbacks: https://docs.fivem.net/docs/scripting-reference/runtimes/lua/functions/RegisterNUICallback/
