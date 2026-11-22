Config = {
    Brand = 'Bright Falls RP',
    ManagerJob = 'trademanager',
    BankRadius = 3.5,
    BankControl = 0xE3BF959B, -- INPUT_CONTEXT_X (R on keyboard)
    BankKeyLabel = 'R',
    Banks = {
        { name = 'Valentine Bank', x = -308.02, y = 773.82, z = 116.70 },
        { name = 'Blackwater Bank', x = -813.18, y = -1277.60, z = 43.68 },
        { name = 'Saint Denis Bank', x = 2644.08, y = -1292.21, z = 52.29 },
        { name = 'Rhodes Bank', x = 1294.14, y = -1303.06, z = 77.04 }
    },
    MinWager = 1,             -- Dollars, whole numbers
    MaxWager = 500,
    MaxPot = 1000000,          -- Dollars, maximum 1,000,000
    MaxOpenMarkets = 25,
    MaxParticipants = 500,     -- Per market
    HistoryDays = 30           -- Fully paid or empty markets only
}

function FindTradeBank(coords)
    local radiusSquared = Config.BankRadius ^ 2
    for _, bank in ipairs(Config.Banks) do
        local distance = (coords.x - bank.x)^2 + (coords.y - bank.y)^2 + (coords.z - bank.z)^2
        if distance <= radiusSquared then return bank end
    end
end
