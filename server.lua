local Core = exports.vorp_core:GetCore()
local storageKey = 'market_ledger_v1'
local raw = GetResourceKvpString(storageKey)
local ledger = raw and json.decode(raw) or nil
if raw and (type(ledger) ~= 'table' or ledger.version ~= 1
    or type(ledger.markets) ~= 'table' or type(ledger.pending) ~= 'table') then
    error('Market ledger could not be loaded. Restore it before starting this resource.')
end
ledger = ledger or { version = 1, nextId = 1, markets = {}, pending = {} }

local payoutLimit = 1000000 -- cents per winning trade
ledger.archivedStats = ledger.archivedStats or {}

ledger.resultInbox = ledger.resultInbox or {}
ledger.nextResultId = ledger.nextResultId or 1
local lastDelivery = {}

local busy = false
local halted = false
local lastRequest = {}

local function persist()
    local ok, message = pcall(function()
        local encoded = json.encode(ledger)
        SetResourceKvp(storageKey, encoded)
        assert(GetResourceKvpString(storageKey) == encoded, 'Ledger write verification failed')
    end)
    if not ok then
        halted = true
        error(message)
    end
end

local function character(src)
    local user = Core.getUser(src)
    local active = user and user.getUsedCharacter
    if not active or not active.identifier or not active.charIdentifier then return end
    return active, tostring(active.identifier) .. '/' .. tostring(active.charIdentifier)
end

local function cash(active)
    local amount = active and tonumber(active.money)
    if amount then return math.floor(amount * 100 + 0.5) end
end

local function status(m)
    if m.status == 'open' and m.closes <= os.time() then return 'closed' end
    return m.status
end

local function finishCash(key, entry, applied, reviewed)
    local m = assert(ledger.markets[tostring(entry.market)])
    if applied and entry.kind == 'buy' then
        if reviewed or status(m) ~= 'open' then
            Book.credit(m, key, entry.amount)
        else
            Book.submit(m, key, entry)
        end
    elseif applied and entry.kind == 'bet' then
        local position = m.positions[key] or { 0, 0 }
        m.trades = m.trades or {}
        local trades = m.trades[key] or {
            position[1] > 0 and { position[1] } or {},
            position[2] > 0 and { position[2] } or {}
        }
        local sideTrades = trades[entry.side]
        sideTrades[#sideTrades + 1] = entry.amount
        m.trades[key] = trades
        position[entry.side] = position[entry.side] + entry.amount
        m.positions[key] = position
        m.totals[entry.side] = m.totals[entry.side] + entry.amount
    elseif applied then
        local remaining = (m.claims[key] or 0) - entry.amount
        assert(remaining >= 0, 'Claim balance mismatch')
        m.claims[key] = remaining > 0 and remaining or nil
    end
    ledger.pending[key] = nil
    persist()
end

local function moveCash(src, key, active, entry)
    entry.before = cash(active)
    local delta = entry.kind ~= 'claim' and -entry.amount or entry.amount
    entry.after = entry.before + delta
    entry.time = os.time()
    entry.name = ((active.firstname or '') .. ' ' .. (active.lastname or ''))
    ledger.pending[key] = entry
    persist()

    local change = delta < 0 and active.removeCurrency or active.addCurrency
    local ok, result = pcall(change, 0, entry.amount / 100)
    local current, currentKey = character(src)
    if ok and result ~= false and currentKey == key and cash(current) == entry.after then
        finishCash(key, entry, true)
        return true
    end
    print(('[bf_markets] Cash review required for %s on market %s'):format(key, entry.market))
    return false
end

local function calculatePayouts(m, winner, historical)
    local payouts = {}
    local winning = winner and m.totals[winner] or 0
    if winning == 0 and not historical then return payouts end

    local keys = {}
    for key in pairs(m.positions) do keys[#keys + 1] = key end
    table.sort(keys)
    local total = m.totals[1] + m.totals[2]
    local cumulative, distributed = 0, 0
    for _, key in ipairs(keys) do
        local position = m.positions[key]
        local amount = 0
        if winning == 0 then
            amount = position[1] + position[2]
        else
            local trades = m.trades and m.trades[key]
            local stakes = trades and trades[winner] or { position[winner] }
            for _, stake in ipairs(stakes) do
                cumulative = cumulative + stake
                local target = (cumulative * total) // winning
                local share = target - distributed
                distributed = target
                amount = amount + (historical and share or math.min(share, payoutLimit))
            end
        end
        if amount > 0 then payouts[key] = amount end
    end
    return payouts
end

local function settledPayout(m, key)
    -- Earlier settlements keep their original entitlements.
    if not m.payouts then
        m.payouts = calculatePayouts(m, m.winner, true)
    end
    return m.payouts[key] or 0
end

local function deliverResult(src, key)
    local inbox = ledger.resultInbox[key]
    local result = inbox and inbox[1]
    if not result then return end
    local sent = lastDelivery[src]
    local now = os.time()
    if sent and sent.id == result.id and now - sent.time < 12 then return end
    lastDelivery[src] = { id = result.id, time = now }
    TriggerClientEvent('bf_markets:result', src, result)
end

RegisterNetEvent('bf_markets:resultSeen', function(id)
    local src = source
    local sent = lastDelivery[src]
    if halted or not sent or sent.id ~= id then return end
    local _, key = character(src)
    local inbox = ledger.resultInbox[key]
    if not inbox or inbox[1].id ~= id then return end
    table.remove(inbox, 1)
    if #inbox == 0 then ledger.resultInbox[key] = nil end
    lastDelivery[src] = nil
    persist()
    deliverResult(src, key)
end)

local function settle(m, winner)
    if m.book then
        Book.resolve(m, winner)
    else
        local payouts = calculatePayouts(m, winner, false)
        m.payouts, m.claims = payouts, {}
        for key, amount in pairs(payouts) do m.claims[key] = amount end
    end
    m.status = 'settled'
    m.winner = winner
    m.finished = os.time()
    for key, position in pairs(m.positions) do
        local net = settledPayout(m, key) - position[1] - position[2]
        if net ~= 0 then
            local inbox = ledger.resultInbox[key] or {}
            inbox[#inbox + 1] = { id = ledger.nextResultId, title = m.title, net = net }
            ledger.nextResultId = ledger.nextResultId + 1
            ledger.resultInbox[key] = inbox
        end
    end
    persist()
    for _, player in ipairs(GetPlayers()) do
        local src = tonumber(player)
        local _, key = character(src)
        if key and m.positions[key] then deliverResult(src, key) end
    end
end

local function addResult(stats, stake, payout)
    local net = payout - stake
    stats.profit = stats.profit + math.max(0, net)
    stats.loss = stats.loss + math.max(0, -net)
    stats.count = stats.count + 1
end

local function newStats()
    return { profit = 0, loss = 0, count = 0 }
end

local function prune()
    local cutoff = os.time() - Config.HistoryDays * 86400
    for id, m in pairs(ledger.markets) do
        if m.finished and m.finished < cutoff and not next(m.claims) then
            for key, position in pairs(m.positions) do
                local stats = ledger.archivedStats[key] or newStats()
                addResult(stats, position[1] + position[2], settledPayout(m, key))
                ledger.archivedStats[key] = stats
            end
            ledger.markets[id] = nil
        end
    end
end

local function snapshot(active, key, admin)
    local markets, reviews, results = {}, {}, {}
    local archived = ledger.archivedStats[key] or newStats()
    local stats = { profit = archived.profit, loss = archived.loss, count = archived.count, exposure = 0 }
    local name = ((active.firstname or '') .. ' ' .. (active.lastname or '')):match('^%s*(.-)%s*$')
    for _, m in pairs(ledger.markets) do
        local position = m.positions[key] or { 0, 0 }
        local claim = m.claims and m.claims[key] or 0
        local stake = position[1] + position[2]
        if stake > 0 then
            if m.finished then
                local payout = settledPayout(m, key)
                addResult(stats, stake, payout)
                if os.time() - m.finished <= Config.HistoryDays * 86400 or claim > 0 then
                    results[#results + 1] = {
                        id = m.id, title = m.title, stake = stake, payout = payout,
                        finished = m.finished, unclaimed = claim > 0
                    }
                end
            else
                stats.exposure = stats.exposure + math.max(0, stake - (m.book and m.book.sales[key] or 0))
            end
        end
        if not m.finished or os.time() - m.finished <= Config.HistoryDays * 86400 or claim > 0 then
            markets[#markets + 1] = {
                id = m.id, title = m.title, rules = m.rules, options = m.options,
                totals = m.totals, closes = m.closes, status = status(m),
                position = position, claim = claim, winner = m.winner,
                book = m.book and Book.view(m, key)
            }
        end
    end
    table.sort(markets, function(a, b) return a.id > b.id end)
    table.sort(results, function(a, b)
        return a.finished > b.finished or (a.finished == b.finished and a.id > b.id)
    end)
    stats.results = results
    if admin then
        for owner, entry in pairs(ledger.pending) do
            reviews[#reviews + 1] = {
                key = owner, name = entry.name, market = entry.market, kind = entry.kind,
                before = entry.before, after = entry.after, time = entry.time
            }
        end
    end
    return {
        name = name, stats = stats, payoutLimit = payoutLimit, admin = admin, markets = markets, reviews = reviews, balance = cash(active),
        pending = ledger.pending[key] ~= nil, min = Config.MinWager, max = Config.MaxWager
    }
end

local function clean(value, max)
    if type(value) ~= 'string' or #value > max or value:find('[%z\1-\8\11\12\14-\31]') then return end
    local trimmed = value:match('^%s*(.-)%s*$')
    if trimmed ~= '' then return trimmed end
end

local function integer(value, min, max)
    if type(value) == 'number' and value >= min and value <= max and value % 1 == 0 then return math.tointeger(value) end
end

local function act(src, data, active, key, admin)
    local action = data.action
    if action == 'view' then return end
    if halted then return 'Markets are temporarily unavailable. Contact a trade manager.' end

    if action == 'review' then
        if not admin then return 'Trade manager job required.' end
        local entry = type(data.key) == 'string' and ledger.pending[data.key]
        if not entry or type(data.applied) ~= 'boolean' then return 'Review no longer available.' end
        finishCash(data.key, entry, data.applied, true)
        print(('[bf_markets] Staff source %s reviewed market %s for %s (applied: %s)'):format(
            src, entry.market, data.key, tostring(data.applied)))
        return nil, 'Cash review saved.'
    end

    if action == 'create' then
        if not admin then return 'Trade manager job required.' end
        local title, rules = clean(data.title, 120), clean(data.rules, 800)
        local first, second = clean(data.first, 40), clean(data.second, 40)
        local minutes = integer(data.minutes, 1, 43200)
        if not title or not rules or not first or not second or first:lower() == second:lower() or not minutes then
            return 'Enter a question, resolution rules, two distinct outcomes and a valid duration.'
        end
        local count = 0
        for _, m in pairs(ledger.markets) do
            if not m.finished then count = count + 1 end
        end
        if count >= Config.MaxOpenMarkets then return 'Settle an existing market first.' end
        local id = ledger.nextId
        ledger.nextId = id + 1
        prune()
        ledger.markets[tostring(id)] = {
            id = id, title = title, rules = rules, options = { first, second },
            closes = os.time() + minutes * 60, status = 'open',
            totals = { 0, 0 }, positions = {}, book = Book.new(), claims = {}, createdBy = key
        }
        persist()
        return nil, 'Market published.'
    end

    local id = integer(data.id, 1, ledger.nextId)
    local m = id and ledger.markets[tostring(id)]
    if not m then return 'Market unavailable.' end

    if m.book and action == 'bet' then return 'Use a share order in this market.' end
    if action == 'cancel' and m.book then
        if not Book.cancel(m, key, data.order) then return 'Open order unavailable.' end
        persist()
        return nil, 'Unfilled quantity canceled.'
    end
    if action == 'buy' or action == 'sell' then
        if not m.book or status(m) ~= 'open' then return 'This market is unavailable for trading.' end
        if ledger.pending[key] then return 'Cash movement awaiting review.' end
        local side = integer(data.side, 1, 2)
        local price = integer(data.price, 1, 99)
        local quantity = integer(data.quantity, 1, payoutLimit // 100)
        if not side or not price or not quantity then return 'Enter whole shares and a price of 1–99 cents.' end
        if #m.book.orders >= 2000 then return 'Order book at capacity.' end
        local entry = { market = id, kind = action, side = side, price = price, quantity = quantity, amount = price * quantity }
        if action == 'sell' then
            if quantity > Book.available(m, key, side) then return 'You have too few available shares.' end
            Book.submit(m, key, entry)
            persist()
        else
            if entry.amount > Config.MaxWager * 100 or entry.amount < Config.MinWager * 100 then
                return 'Buy order value must be between $' .. Config.MinWager .. ' and $' .. Config.MaxWager .. '.'
            end
            local committed, participants = m.book.collateral, {}
            for owner in pairs(m.positions) do participants[owner] = true end
            for _, order in ipairs(m.book.orders) do
                participants[order.owner] = true
                if order.kind == 'buy' then committed = committed + order.left * order.price end
            end
            local count = 0
            for _ in pairs(participants) do count = count + 1 end
            if not participants[key] and count >= Config.MaxParticipants then return 'This market is at capacity.' end
            if committed + entry.amount > Config.MaxPot * 100 then return 'This exceeds the market cash limit.' end
            if (cash(active) or 0) < entry.amount then return 'Insufficient cash for this limit order.' end
            if not moveCash(src, key, active, entry) then return 'Cash movement pending trade manager review.' end
        end
        return nil, 'Order accepted.'
    end

    if action == 'bet' or action == 'claim' then
        if ledger.pending[key] then return 'A cash movement on this character is awaiting trade manager review.' end
        if not cash(active) then return 'Character cash is unavailable.' end

        local entry = { kind = action, market = id }
        if action == 'bet' then
            if status(m) ~= 'open' then return 'This market is closed.' end
            local dollars = integer(data.amount, Config.MinWager, Config.MaxWager)
            local side = integer(data.side, 1, 2)
            if not dollars or not side then return 'Choose an outcome and enter a valid whole-dollar wager.' end
            entry.side, entry.amount = side, dollars * 100
            if cash(active) < entry.amount then return 'You do not have enough cash.' end
            local reserved, participants = 0, 0
            for _ in pairs(m.positions) do participants = participants + 1 end
            for owner, pending in pairs(ledger.pending) do
                if pending.market == id and pending.kind == 'bet' then
                    reserved = reserved + pending.amount
                    if not m.positions[owner] then participants = participants + 1 end
                end
            end
            if not m.positions[key] and participants >= Config.MaxParticipants then return 'This market is at capacity.' end
            if m.totals[1] + m.totals[2] + reserved + entry.amount > math.min(Config.MaxPot, 1000000) * 100 then
                return 'That wager would exceed the market pool limit.'
            end
        else
            entry.amount = m.claims and m.claims[key]
            if not entry.amount then return 'There is no cash to claim on this market.' end
        end
        if not moveCash(src, key, active, entry) then return 'Cash movement pending trade manager review.' end
        return nil, action == 'bet' and 'Wager placed.' or 'Cash collected.'
    end

    if not admin then return 'Trade manager job required.' end
    if action == 'close' and status(m) == 'open' then
        if m.book then Book.expire(m) end
        m.status = 'closed'
        persist()
        return nil, 'Wagering closed.'
    end
    if action == 'settle' and status(m) == 'closed' then
        for _, entry in pairs(ledger.pending) do
            if entry.market == id then return 'Review the pending cash movement before settling.' end
        end
        local winner = integer(data.side, 1, 2)
        if not winner then return 'Choose the winning outcome.' end
        settle(m, winner)
        return nil, next(m.claims) and 'Winnings are ready to claim.' or 'Market settled with no winning payouts.'
    end
    return 'That action is unavailable.'
end

RegisterNetEvent('bf_markets:request', function(data)
    local src = source
    if type(data) ~= 'table' then return end
    local now = GetGameTimer()
    local category = data.action == 'view' and 'read' or 'write'
    local times = lastRequest[src] or {}
    local previous = times[category]
    if previous and now - previous >= 0 and now - previous < 350 then
        TriggerClientEvent('bf_markets:response', src, { error = 'Please wait a moment.' })
        return
    end
    times[category] = now
    lastRequest[src] = times
    if busy then
        TriggerClientEvent('bf_markets:response', src, { error = 'Markets are busy. Try again.' })
        return
    end

    busy = true
    local ok, response = xpcall(function()
        local active, key = character(src)
        if not active then return { error = 'Select a character first.' } end
        local ped = GetPlayerPed(src)
        if ped == 0 or not FindTradeBank(GetEntityCoords(ped)) then
            return { outsideBank = true }
        end
        if not halted then
            local changed = false
            for _, market in pairs(ledger.markets) do
                if market.book and status(market) == 'closed' and Book.expire(market) then changed = true end
            end
            if changed then persist() end
        end
        local admin = active.job == Config.ManagerJob
        local message, notice = act(src, data, active, key, admin)
        local current, currentKey = character(src)
        if currentKey ~= key then return { error = 'Character changed. Reopen the exchange.' } end
        deliverResult(src, key)
        local state = snapshot(current, key, admin)
        state.error, state.notice = message, notice
        return state
    end, debug.traceback)
    busy = false
    if not ok then
        print(response)
        response = { error = 'Market service error. Contact a trade manager if cash moved.' }
    end
    TriggerClientEvent('bf_markets:response', src, response)
end)

AddEventHandler('playerDropped', function()
    lastRequest[source] = nil
    lastDelivery[source] = nil
end)
