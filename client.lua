local visible = false

local function close()
    visible = false
    SetNuiFocus(false, false)
    SendNUIMessage({ type = 'close' })
end

local function open(bank)
    visible = true
    SetNuiFocus(true, true)
    SendNUIMessage({ type = 'open', bank = bank.name, brand = Config.Brand })
end

CreateThread(function()
    while true do
        local ped = PlayerPedId()
        local bank = ped ~= 0 and not IsEntityDead(ped) and FindTradeBank(GetEntityCoords(ped))
        if not bank then
            if visible then close() end
            Wait(250)
        elseif visible then
            Wait(150)
        else
            local label = CreateVarString(10, 'LITERAL_STRING', '[' .. Config.BankKeyLabel .. '] Prediction Exchange')
            SetTextScale(0.35, 0.35)
            SetTextColor(246, 242, 219, 255)
            SetTextCentre(true)
            DisplayText(label, 0.5, 0.87)
            if IsControlJustReleased(0, Config.BankControl) then open(bank) end
            Wait(0)
        end
    end
end)

RegisterNUICallback('close', function(_, cb)
    close()
    cb({})
end)

RegisterNUICallback('request', function(data, cb)
    if visible then TriggerServerEvent('bf_markets:request', data) end
    cb({})
end)

RegisterNetEvent('bf_markets:result', function(result)
    SendNUIMessage({ type = 'settlementResult', result = result })
end)

RegisterNUICallback('resultSeen', function(data, cb)
    TriggerServerEvent('bf_markets:resultSeen', data.id)
    cb({})
end)

RegisterNetEvent('bf_markets:response', function(data)
    if not visible then return end
    if data.outsideBank then close(); return end
    data.type = 'response'
    SendNUIMessage(data)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() and visible then
        SetNuiFocus(false, false)
    end
end)
