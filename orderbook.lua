-- Prices and cash are integer cents. One complementary pair is backed by $1.
Book = {}

function Book.new()
    return { orders = {}, nextId = 1, shares = {}, sales = {}, tape = {}, volume = 0, collateral = 0 }
end

local function credit(m, key, amount)
    if amount > 0 then m.claims[key] = (m.claims[key] or 0) + amount end
end
Book.credit = credit

local function yesPrice(order)
    return order.side == 1 and order.price or 100 - order.price
end

local function isBid(order)
    return (order.side == 1) == (order.kind == 'buy')
end

local function fill(m, order, quantity, price)
    local book, key, side = m.book, order.owner, order.side
    local holdings = book.shares[key] or { 0, 0 }
    local costs = m.positions[key] or { 0, 0 }
    local cost = quantity * price
    if order.kind == 'buy' then
        holdings[side] = holdings[side] + quantity
        costs[side] = costs[side] + cost
        credit(m, key, quantity * (order.price - price))
        book.collateral = book.collateral + cost
    else
        holdings[side] = holdings[side] - quantity
        book.sales[key] = (book.sales[key] or 0) + cost
        credit(m, key, cost)
        book.collateral = book.collateral - cost
    end
    m.positions[key], book.shares[key] = costs, holdings
    order.left = order.left - quantity
end

function Book.submit(m, key, entry)
    local b = m.book
    local incoming = { id = b.nextId, owner = key, side = entry.side, kind = entry.kind,
        price = entry.price, left = entry.quantity }
    b.nextId = b.nextId + 1
    local bid, limit, candidates = isBid(incoming), yesPrice(incoming), {}
    for _, maker in ipairs(b.orders) do
        local quote = yesPrice(maker)
        if maker.owner ~= key and isBid(maker) ~= bid and
            ((bid and quote <= limit) or (not bid and quote >= limit)) then
            candidates[#candidates + 1] = maker
        end
    end
    table.sort(candidates, function(a, other)
        local x, y = yesPrice(a), yesPrice(other)
        if x == y then return a.id < other.id end
        if bid then return x < y end
        return x > y
    end)
    for _, maker in ipairs(candidates) do
        if incoming.left == 0 then break end
        local quantity = math.min(maker.left, incoming.left)
        local price = yesPrice(maker)
        fill(m, maker, quantity, maker.price)
        fill(m, incoming, quantity, incoming.side == 1 and price or 100 - price)
        b.volume = b.volume + quantity
        b.tape[#b.tape + 1] = { time = os.time(), price = price, quantity = quantity }
        if #b.tape > 180 then table.remove(b.tape, 1) end
    end
    local orders = {}
    for _, maker in ipairs(b.orders) do
        if maker.left > 0 then orders[#orders + 1] = maker end
    end
    if incoming.left > 0 then orders[#orders + 1] = incoming end
    b.orders = orders
end

local function release(m, order)
    if order.kind == 'buy' then credit(m, order.owner, order.price * order.left) end
end

function Book.cancel(m, key, id)
    for i, order in ipairs(m.book.orders) do
        if order.id == id and order.owner == key then
            release(m, order)
            table.remove(m.book.orders, i)
            return true
        end
    end
end

function Book.expire(m)
    if #m.book.orders == 0 then return false end
    for _, order in ipairs(m.book.orders) do release(m, order) end
    m.book.orders = {}
    return true
end

function Book.resolve(m, winner)
    Book.expire(m)
    m.payouts = {}
    for key, shares in pairs(m.book.shares) do
        local winnings = shares[winner] * 100
        credit(m, key, winnings)
        m.payouts[key] = winnings + (m.book.sales[key] or 0)
    end
end

function Book.available(m, key, side)
    local shares = m.book.shares[key]
    local available = shares and shares[side] or 0
    for _, order in ipairs(m.book.orders) do
        if order.kind == 'sell' and order.owner == key and order.side == side then
            available = available - order.left
        end
    end
    return available
end

function Book.view(m, key)
    local levels, mine = { {}, {} }, {}
    for _, order in ipairs(m.book.orders) do
        local price = yesPrice(order)
        local side = levels[isBid(order) and 1 or 2]
        side[price] = (side[price] or 0) + order.left
        if order.owner == key then
            mine[#mine + 1] = { id = order.id, side = order.side, kind = order.kind,
                price = order.price, quantity = order.left }
        end
    end
    local bids, asks = {}, {}
    for p = 1, 99 do
        if levels[1][100-p] then bids[#bids+1] = { price = 100-p, quantity = levels[1][100-p] } end
        if levels[2][p] then asks[#asks+1] = { price = p, quantity = levels[2][p] } end
    end
    return { bids = bids, asks = asks, mine = mine, tape = m.book.tape, volume = m.book.volume,
        shares = m.book.shares[key] or {0, 0}, spent = m.positions[key] or {0, 0},
        sold = m.book.sales[key] or 0 }
end
