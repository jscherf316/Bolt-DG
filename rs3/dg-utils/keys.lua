local Keys = {}

function Keys.getHeld()
    local held = {}
    for keyNumber = 1, 64 do
        if var.VarClient["TOOLBELT_RAND_KEY_" .. keyNumber].value == 1 then
            held[#held + 1] = keyNumber
        end
    end
    return held
end

return Keys
