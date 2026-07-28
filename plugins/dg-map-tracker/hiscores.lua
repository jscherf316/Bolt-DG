-- Player skill levels from the RS3 hiscores API (2026-07-28).
--
-- The Lua sandbox has no network access, so the fetch runs in the always-on
-- settings TRIGGER page (settings_trigger.html) -- bolt relaunches its CEF
-- with --disable-web-security (src/main.cxx), so a plugin:// page can fetch
-- secure.runescape.com directly, no proxy. Flow:
--   trigger page loads -> posts "ready"
--   settings_panel.lua routes "ready"/"hs_*" messages here via SET hooks
--   we send "hs_fetch:<display name>" (name from bolt.charactername())
--   page fetches index_lite.ws with retries, posts "hs_ok:<csv>" / "hs_err:_"
--   we parse into SET.skills = { attack = 99, ... } and cache to settings
--
-- The cache ("hiscores_cache") is an OFFLINE FALLBACK keyed by display name:
-- loaded at startup so skill-door logic has levels even if this session's
-- fetch fails. Levels only rise, so a stale level errs conservative (a door
-- we could actually pass may show as blocked, never the reverse).
--
-- CSV shape: line 1 is Overall (rank,total,xp), then one "rank,level,xp"
-- line per skill in skill-ID order, then activity lines (ignored). Unranked
-- skills come back "-1,-1,-1" and are stored as nil (unknown).
return function (deps)
  local bolt = require("bolt")
  local SET = deps.SET
  local HS = {}
  SET.hs = HS

  -- RS3 skill-ID order. VERIFY against a live hs_raw.txt before trusting
  -- door decisions: compare a few known levels, especially the tail
  -- (invention/archaeology/necromancy) where an order slip is invisible
  -- unless the levels differ.
  local SKILLS = {
    "attack", "defence", "strength", "constitution", "ranged", "prayer",
    "magic", "cooking", "woodcutting", "fletching", "fishing", "firemaking",
    "crafting", "smithing", "mining", "herblore", "agility", "thieving",
    "slayer", "farming", "runecrafting", "hunter", "construction",
    "summoning", "dungeoneering", "divination", "invention", "archaeology",
    "necromancy",
  }
  HS.SKILLS = SKILLS

  local function diag(text)
    SET.dev_save("hs_diag.txt", text)
  end

  -- SET.skills: skill name -> level, nil until something loads it.
  local function apply(levels, source)
    SET.skills = levels
    local parts = {}
    for _, sk in ipairs(SKILLS) do
      parts[#parts + 1] = sk .. "=" .. tostring(levels[sk])
    end
    diag("source: " .. source .. "\n" .. table.concat(parts, "\n"))
  end

  local function parse_csv(text)
    local lines = {}
    for line in text:gmatch("[^\r\n]+") do lines[#lines + 1] = line end
    -- line 1 = overall, skills start at line 2
    if #lines < #SKILLS + 1 then return nil, "short response: " .. #lines .. " lines" end
    local levels = {}
    for i, sk in ipairs(SKILLS) do
      local level = lines[i + 1]:match("^[%-%d]+,([%-%d]+),")
      level = tonumber(level)
      if level and level > 0 then levels[sk] = level end
    end
    if not levels.attack then return nil, "no attack level parsed" end
    return levels
  end

  -- ---- message hooks (called by settings_panel.lua's trigger onmessage) ----

  -- Trigger page finished loading: it can receive sendmessage now.
  function SET.hs_trigger_ready()
    local name = bolt.charactername()
    if not name or name == "" then
      diag("no character name (JX_DISPLAY_NAME unset); using cache only")
      return
    end
    HS.player = name
    local trig = SET.cpanel and SET.cpanel.trigger
    if trig then trig:sendmessage("hs_fetch:" .. name) end
  end

  function SET.hs_onmsg(msg)
    if msg:sub(1, 6) == "hs_ok:" then
      -- "hs_ok:<transport>:<csv>" -- the page names which leg won (direct is
      -- tried first and is expected to fail on stock bolt; see the CORS note
      -- in settings_trigger.html).
      local body = msg:sub(7)
      local transport, rest = body:match("^(%a[%w_]*):(.*)$")
      if transport then
        HS.transport = transport
        body = rest
      end
      bolt.saveconfig("hs_raw.txt", body)   -- always kept: the order-verification artifact
      local levels, err = parse_csv(body)
      if levels then
        apply(levels, ("live fetch via %s (%s)"):format(
          tostring(HS.transport or "?"), tostring(HS.player)))
        SET.set("hiscores_cache", { name = HS.player, levels = levels })
      else
        diag("parse failed: " .. tostring(err))
      end
    elseif msg:sub(1, 7) == "hs_err:" then
      diag("fetch failed after retries: " .. msg:sub(8)
        .. (SET.skills and " (cache in use)" or " (NO levels available)"))
    end
  end

  -- ---- startup: seed from cache so levels exist before/without the fetch ----
  do
    local cached = SET.get("hiscores_cache", nil)
    local name = bolt.charactername()
    if type(cached) == "table" and type(cached.levels) == "table"
       and (name == nil or cached.name == name) then
      local levels = {}
      for _, sk in ipairs(SKILLS) do
        levels[sk] = tonumber(cached.levels[sk])
      end
      apply(levels, "cache (" .. tostring(cached.name) .. ")")
    end
  end
end
