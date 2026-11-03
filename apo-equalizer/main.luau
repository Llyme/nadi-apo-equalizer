--!strict
-- Equalizer: Equalizer APO from NADI.
--
-- The plugin keeps its presets and draws the equalizer; its helper (bin/apo-helper.exe) reads Equalizer APO's configuration, writes the
-- plugin's own file into Equalizer APO's config folder and points config.txt at it (off: back at what it named before), and keeps the
-- plugin's state.
--
-- A preset: its preamp, its bands (each a frequency, a gain, a Q and a type, Equalizer APO's: PK, LS, HS, LP, HP, BP, NO, AP), which
-- channels the bands apply to, the device, and each speaker's volume and delay, how the channels are mixed, and the balance.
-- Changes are heard at once but kept apart from the preset (its draft) until saved; undo and redo step through them.

local FS = 48000 -- the rate the curve is reckoned at
local F_MIN, F_MAX = 10, 22000
local G_MIN, G_MAX = -30, 30
local PRE_MIN, PRE_MAX = -30, 20
local POINTS = 300 -- the curve's values, evenly across (in octaves)
local UNDO_MAX = 60

local TYPES = { "PK", "LS", "HS", "LP", "HP", "BP", "NO", "AP" }
local TYPE_NAME = {
	PK = "Peak",
	LS = "Low Shelf",
	HS = "High Shelf",
	LP = "Low Pass",
	HP = "High Pass",
	BP = "Band Pass",
	NO = "Notch",
	AP = "All Pass",
}
-- (the types with a gain)
local HAS_GAIN = { PK = true, LS = true, HS = true }
local SPEAKERS = { "L", "R", "C", "SUB", "RL", "RR", "SL", "SR" }
local SPEAKER_NAME = { L = "L", R = "R", C = "C", SUB = "Sub", RL = "Rear L", RR = "Rear R", SL = "Side L", SR = "Side R" }
local LAYOUTS = {
	["10"] = { 31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 },
	["15"] = { 25, 40, 63, 100, 160, 250, 400, 630, 1000, 1600, 2500, 4000, 6300, 10000, 16000 },
	["31"] = { 20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000 },
}

-- ---------------------------------------------------------------------------------------------------------------- state

type Band = { f: number, g: number, q: number, t: string }
type Preset = {
	preamp: number,
	bands: { Band },
	channels: string,
	device: string,
	spk: { [string]: { v: number, d: number } },
	mix: string,
	bal: number,
}

local S = {
	ready = false, -- the helper has answered
	apo = false, -- Equalizer APO is installed
	writable = true,
	on = true,
	guard = false, -- (Clip Guard: off at first)
	step = 0.5, -- the preamp's step (dB): dragged, the wheel, typed
	presets = {} :: { [string]: Preset },
	order = {} :: { string },
	current = "",
	drafts = {} :: { [string]: Preset },
	sets = {} :: { [number]: Preset? },
	devices = {} :: { string },
	theirs = "",
	problem = "",
}
-- (not kept)
local UI = {
	sel = 0,
	spk = false, -- the speakers shown
	undo = {} :: { Preset },
	redo = {} :: { Preset },
	drag_action = "",
	drag_at = 0,
	pending = false,
	last_apply = 0,
	win = false,
}

local function copy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local o = {}
	for k, x in v do
		o[k] = copy(x)
	end
	return o
end

local function blank(): Preset
	return { preamp = 0, bands = {}, channels = "all", device = "all", spk = {}, mix = "stereo", bal = 0 }
end

-- (a preset as it came, tidied: every field there)
local function tidy(p: any): Preset
	local o = blank()
	if type(p) ~= "table" then
		return o
	end
	o.preamp = tonumber(p.preamp) or 0
	for _, b in p.bands or {} do
		table.insert(o.bands, { f = tonumber(b.f) or 1000, g = tonumber(b.g) or 0, q = tonumber(b.q) or 1.41, t = b.t or "PK" })
	end
	o.channels = p.channels or "all"
	o.device = p.device or "all"
	o.spk = copy(p.spk or {})
	o.mix = p.mix or "stereo"
	o.bal = tonumber(p.bal) or 0
	return o
end

local function edited(): boolean
	return S.drafts[S.current] ~= nil
end

-- What is heard now: its draft, else the preset.
local function cur(): Preset
	return S.drafts[S.current] or S.presets[S.current] or blank()
end

local function sort_bands(p: Preset)
	table.sort(p.bands, function(a, b)
		return a.f < b.f
	end)
end

-- ---------------------------------------------------------------------------------------------------------------- the curve

local function biquad(b: Band)
	local w0 = 2 * math.pi * math.clamp(b.f, 1, FS / 2 - 1) / FS
	local c, s = math.cos(w0), math.sin(w0)
	local q = math.max(b.q, 0.05)
	local A = 10 ^ (b.g / 40)
	local alpha = s / (2 * q)
	local t = b.t
	if t == "PK" then
		return 1 + alpha * A, -2 * c, 1 - alpha * A, 1 + alpha / A, -2 * c, 1 - alpha / A
	elseif t == "LP" then
		return (1 - c) / 2, 1 - c, (1 - c) / 2, 1 + alpha, -2 * c, 1 - alpha
	elseif t == "HP" then
		return (1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha
	elseif t == "BP" then
		return alpha, 0, -alpha, 1 + alpha, -2 * c, 1 - alpha
	elseif t == "NO" then
		return 1, -2 * c, 1, 1 + alpha, -2 * c, 1 - alpha
	elseif t == "LS" or t == "HS" then
		-- (a shelf of slope 1)
		local sa = math.sqrt(A)
		local al = s / 2 * math.sqrt(2)
		if t == "LS" then
			return A * ((A + 1) - (A - 1) * c + 2 * sa * al), 2 * A * ((A - 1) - (A + 1) * c), A * ((A + 1) - (A - 1) * c - 2 * sa * al), (A + 1) + (A - 1) * c + 2 * sa * al, -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - 2 * sa * al
		end
		return A * ((A + 1) + (A - 1) * c + 2 * sa * al), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - 2 * sa * al), (A + 1) - (A - 1) * c + 2 * sa * al, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - 2 * sa * al
	end
	return nil -- (all pass: its loudness flat)
end

local function db_at(co: { number }, f: number): number
	local w = 2 * math.pi * f / FS
	local c1, s1, c2, s2 = math.cos(w), math.sin(w), math.cos(2 * w), math.sin(2 * w)
	local br, bi = co[1] + co[2] * c1 + co[3] * c2, -(co[2] * s1 + co[3] * s2)
	local ar, ai = co[4] + co[5] * c1 + co[6] * c2, -(co[5] * s1 + co[6] * s2)
	local m = math.sqrt((br * br + bi * bi) / math.max(ar * ar + ai * ai, 1e-30))
	return 20 * math.log(math.max(m, 1e-6), 10)
end

-- The curve's frequencies, evenly across in octaves.
local function freq_at(i: number): number
	return F_MIN * (F_MAX / F_MIN) ^ ((i - 1) / (POINTS - 1))
end

-- How loud each band makes each frequency, summed: the curve (without the preamp).
local function response(p: Preset): { number }
	local cos = {}
	for _, b in p.bands do
		local b0, b1, b2, a0, a1, a2 = biquad(b)
		if b0 then
			table.insert(cos, { b0, b1, b2, a0, a1, a2 })
		end
	end
	local out = table.create(POINTS, 0)
	for i = 1, POINTS do
		local f = freq_at(i)
		local sum = 0
		for _, co in cos do
			sum += db_at(co, f)
		end
		out[i] = sum
	end
	return out
end

-- The loudest the curve gets (0 at least): what Clip Guard keeps the preamp under.
local function peak(line: { number }): number
	local m = 0
	for _, v in line do
		m = math.max(m, v)
	end
	return m
end

local function guard_preamp(p: Preset, line: { number }?)
	if not S.guard then
		return
	end
	local top = -peak(line or response(p))
	if p.preamp > top then
		p.preamp = math.floor(top * 10) / 10
	end
end

-- ---------------------------------------------------------------------------------------------------------------- Equalizer APO's words

local function num(v: number): string
	local s = string.format("%.2f", v)
	s = s:gsub("0+$", ""):gsub("%.$", "")
	return s
end

local function filter_line(i: number, b: Band): string
	local f, g, q = num(b.f), num(b.g), num(b.q)
	local t = b.t
	local spec
	if t == "PK" then
		spec = `PK Fc {f} Hz Gain {g} dB Q {q}`
	elseif t == "LS" or t == "HS" then
		spec = `{t} Fc {f} Hz Gain {g} dB`
	elseif t == "LP" or t == "HP" then
		spec = `{t}Q Fc {f} Hz Q {q}`
	else
		spec = `{t} Fc {f} Hz Q {q}`
	end
	return `Filter {i}: ON {spec}`
end

local MIX = {
	stereo = nil,
	mono = "Copy: L=0.5*L+0.5*R R=0.5*L+0.5*R",
	swap = "Copy: L=R R=L",
	left = "Copy: L=L R=L",
	right = "Copy: L=R R=R",
}

-- What Equalizer APO reads: the device, each speaker's volume and delay, the mix, then the preamp and the bands on their channels.
local function apo_text(p: Preset): string
	local lines = {}
	table.insert(lines, `Device: {if p.device == "all" then "all" else p.device}`)
	if not S.on then
		return table.concat(lines, "\n") .. "\n"
	end
	if MIX[p.mix] then
		table.insert(lines, "Channel: all")
		table.insert(lines, MIX[p.mix])
	end
	for _, ch in SPEAKERS do
		local sp = p.spk[ch]
		local v = (sp and sp.v or 0) + (if ch == "L" and p.bal > 0 then -p.bal elseif ch == "R" and p.bal < 0 then p.bal else 0)
		local d = sp and sp.d or 0
		if math.abs(v) > 0.001 or d > 0.001 then
			table.insert(lines, `Channel: {ch}`)
			if math.abs(v) > 0.001 then
				table.insert(lines, `Preamp: {num(v)} dB`)
			end
			if d > 0.001 then
				table.insert(lines, `Delay: {num(d)} ms`)
			end
		end
	end
	table.insert(lines, `Channel: {p.channels}`)
	table.insert(lines, `Preamp: {num(p.preamp)} dB`)
	for i, b in p.bands do
		table.insert(lines, filter_line(i, b))
	end
	return table.concat(lines, "\n") .. "\n"
end

-- ---------------------------------------------------------------------------------------------------------------- what is sent

local out_helper = {} :: { any }

local function save_state()
	table.insert(out_helper, {
		cmd = "save",
		state = { on = S.on, guard = S.guard, step = S.step, presets = S.presets, order = S.order, current = S.current, drafts = S.drafts, sets = S.sets },
	})
end

-- Heard: the curve written (dragged, a few times a second only; `force`: now).
local function apply(now: number, force: boolean?)
	if not S.apo or not S.on then
		return
	end
	if not force and now - UI.last_apply < 120 then
		return
	end
	UI.last_apply = now
	table.insert(out_helper, { cmd = "apply", text = apo_text(cur()) })
end

-- A change about to be made to what is heard: the draft made (the preset as it was, kept apart), the step kept for undo.
local function begin_edit()
	local p = cur()
	table.insert(UI.undo, copy(p))
	if #UI.undo > UNDO_MAX then
		table.remove(UI.undo, 1)
	end
	UI.redo = {}
	if not S.drafts[S.current] then
		S.drafts[S.current] = copy(p)
	end
end

local function put_on(name: string)
	if S.presets[name] or S.drafts[name] then
		S.current = name
		UI.undo, UI.redo, UI.sel = {}, {}, 0
	end
end

local function unique(name: string): string
	if not S.presets[name] then
		return name
	end
	local n = 2
	while S.presets[`{name} {n}`] do
		n += 1
	end
	return `{name} {n}`
end

local function add_preset(name: string, p: Preset): string
	local n = unique(name)
	S.presets[n] = p
	table.insert(S.order, n)
	return n
end

-- The first start: Flat, and what Equalizer APO plays now (read once) as "Now", put on.
local function first_presets(data: any)
	add_preset("Flat", blank())
	if type(data.current) == "table" and #(data.current.bands or {}) > 0 then
		S.current = add_preset("Now", tidy(data.current))
	else
		S.current = "Flat"
	end
end

-- ---------------------------------------------------------------------------------------------------------------- drawing

local function fmt_f(f: number): string
	if f >= 1000 then
		return `{num(f / 1000)}k`
	end
	return num(f)
end

local function db(v: number): string
	if v > 0 then
		return `+{num(v)} dB`
	end
	return `{num(v)} dB`
end

local function frac_pre(v: number): number
	return (v - PRE_MIN) / (PRE_MAX - PRE_MIN)
end

local OWN_UNDO, OWN_REDO, OWN_SAVE = "own:undo.svg", "own:redo.svg", "own:save.svg"
local OWN_FLAT, OWN_BANDS, OWN_SPEAKERS = "own:flat.svg", "own:bands.svg", "own:speakers.svg"

local function button(icon: string, tip: string, action: string?, extra: any?): any
	local b: any = { kind = "button", icon = icon, tip = tip, action = action }
	for k, v in extra or {} do
		b[k] = v
	end
	return b
end

local function preamp_slider(p: Preset, after: any?): any
	return { kind = "slider", wheel = false, icon = "volume", value = frac_pre(p.preamp), text = db(p.preamp), range = { min = PRE_MIN, max = PRE_MAX, unit = "dB", sign = true, step = S.step }, action = "preamp", after = after }
end

-- The presets, as the pill's menu: each one (the one on lit), then save as new and delete.
local function presets_menu(): { any }
	local items = {}
	for _, n in S.order do
		table.insert(items, { icon = "sliders", label = if S.drafts[n] then `{n} *` else n, action = `preset:{n}`, on = n == S.current })
	end
	table.insert(items, { icon = "plus", label = "Save as New", action = "save_new" })
	if #S.order > 1 then
		table.insert(items, { icon = "trash", label = "Delete", action = `del:{S.current}`, tone = "no" })
	end
	return items
end

local function curve_block(p: Preset, line: { number }): any
	local pts = {}
	for i, b in p.bands do
		table.insert(pts, { id = tostring(i), x = b.f, y = if HAS_GAIN[b.t] then b.g else 0 })
	end
	-- (the bands' own curve, their points on it; faint behind it, as heard, its preamp in it)
	local own = table.create(#line, 0)
	local heard = table.create(#line, 0)
	for i, v in line do
		own[i] = math.clamp(v, G_MIN, G_MAX)
		heard[i] = math.clamp(v + p.preamp, G_MIN, G_MAX)
	end
	return {
		kind = "curve",
		height = 240,
		x = { min = F_MIN, max = F_MAX, log = true, marks = { { v = 100, t = "100" }, { v = 1000, t = "1k" }, { v = 10000, t = "10k" } } },
		y = { min = G_MIN, max = G_MAX, marks = { { v = 0, t = "" }, { v = 15, t = "+15" }, { v = -15, t = "-15" } } },
		line = own,
		ghost = if p.preamp ~= 0 then heard else nil,
		points = pts,
		selected = if UI.sel > 0 then tostring(UI.sel) else "",
		off = not S.on,
		drag = "band_drag",
		pick = "band_pick",
		add = "band_add",
		wheel = "band_wheel",
	}
end

-- The band picked: its type, its numbers (typed), remove.
local function band_row(b: Band): any
	local types = {}
	for _, t in TYPES do
		table.insert(types, { icon = `own:{string.lower(t)}.svg`, value = t, tip = TYPE_NAME[t] })
	end
	local items: { any } = { { kind = "seg", options = types, value = b.t, action = "band_type" }, { kind = "space" } }
	table.insert(items, { kind = "num", text = fmt_f(b.f), unit = "Hz", action = "band_hz", tip = "Frequency" })
	if HAS_GAIN[b.t] then
		table.insert(items, { kind = "num", text = (if b.g > 0 then "+" else "") .. num(b.g), unit = "dB", action = "band_db", tip = "Gain" })
	end
	if b.t ~= "LS" and b.t ~= "HS" then
		table.insert(items, { kind = "num", text = num(b.q), unit = "Q", action = "band_qq", tip = "Q" })
	end
	table.insert(items, button("trash", "Remove", "band_remove", { tone = "no" }))
	return { kind = "row", items = items }
end

local function speakers_body(p: Preset): { any }
	local body = {}
	for _, ch in { "L", "R", "C", "SUB" } do
		local sp = p.spk[ch] or { v = 0, d = 0 }
		table.insert(body, { kind = "slider", wheel = false, name = SPEAKER_NAME[ch], icon = "volume", value = (sp.v + 20) / 30, text = db(sp.v), range = { min = -20, max = 10, unit = "dB", sign = true }, action = `spk_v:{ch}` })
		table.insert(body, { kind = "slider", wheel = false, icon = "clock", value = sp.d / 30, text = `{num(sp.d)} ms`, range = { min = 0, max = 30, unit = "ms" }, action = `spk_d:{ch}` })
	end
	table.insert(body, { kind = "row", items = {
		{ kind = "seg", value = p.mix, action = "mix", options = {
			{ text = "Stereo", value = "stereo" },
			{ text = "Mono", value = "mono" },
			{ text = "Swap", value = "swap" },
			{ text = "L", value = "left" },
			{ text = "R", value = "right" },
		} },
	} })
	table.insert(body, { kind = "slider", wheel = false, icon = "sliders", value = (p.bal + 12) / 24, text = if math.abs(p.bal) < 0.05 then "0" elseif p.bal > 0 then `R {num(p.bal)}` else `L {num(-p.bal)}`, range = { min = -12, max = 12, sign = true }, action = "bal" })
	return body
end

local function widgets(): any
	if not S.ready then
		return { eq = { peek = { icon = "sliders", text = "..." }, idle = true } }
	end
	local p = cur()
	if not S.apo then
		return { eq = { peek = { icon = "sliders", text = "No APO" } } }
	end
	local pre = db(p.preamp)
	local power = { kind = "switch", on = S.on, action = "power", tip = if S.on then "Off" else "On" }
	-- (at its widget: the preamp, on or off, reset)
	local small: { any }
	if S.on then
		-- (one line: on or off, the preamp, and Reset when something changed)
		local slider = preamp_slider(p)
		slider.kind = "slider"
		local items: { any } = { power, slider }
		if edited() then
			table.insert(items, button("reset", "Reset", "revert", { dot = true }))
		end
		small = { { kind = "row", items = items } }
	else
		small = { { kind = "row", items = { power } } }
	end
	-- (popped out: the whole of it, on one page)
	-- (its top: the preset, then what can be done now (undo, redo, save; none of them while there is nothing to do), on or off)
	local top: { any } = { { kind = "pill", icon = "sliders", text = S.current, dot = edited(), menu = presets_menu() }, { kind = "space" } }
	if #UI.undo > 0 then
		table.insert(top, button(OWN_UNDO, "Undo", "undo"))
	end
	if #UI.redo > 0 then
		table.insert(top, button(OWN_REDO, "Redo", "redo"))
	end
	if edited() then
		table.insert(top, button(OWN_SAVE, "Save", "save", { on = true }))
		table.insert(top, button("reset", "Reset", "revert"))
	end
	table.insert(top, power)
	local whole: { any } = { { kind = "row", items = top } }
	if S.on then
		local line = response(p)
		table.insert(whole, curve_block(p, line))
		local b = p.bands[UI.sel]
		if b then
			table.insert(whole, band_row(b))
		end
		-- (the preamp; its step, typed; Clip Guard)
		local slider = preamp_slider(p)
		slider.kind = "slider"
		table.insert(whole, { kind = "row", items = {
			slider,
			{ kind = "num", text = num(S.step), unit = "dB", action = "step", tip = "Steps" },
			button("shield", "Clip Guard", "guard", { on = S.guard }),
		} })
		table.insert(whole, { kind = "rule" })
		local devices = { { icon = "speaker", label = "All Devices", action = "device:all", on = p.device == "all" } }
		for _, d in S.devices do
			table.insert(devices, { icon = "speaker", label = d, action = `device:{d}`, on = p.device == d })
		end
		table.insert(whole, { kind = "row", items = {
			button(OWN_FLAT, "Flatten", "flatten"),
			button("expand", "Expand", "expand"),
			button("shrink", "Compress", "compress"),
			{ kind = "seg", value = p.channels, action = "channels", options = { { text = "All", value = "all" }, { text = "L", value = "L" }, { text = "R", value = "R" } } },
			{ kind = "space" },
			button(OWN_BANDS, "Even Bands", nil, { menu = {
				{ icon = "sliders", label = "10 Bands", action = "layout:10" },
				{ icon = "sliders", label = "15 Bands", action = "layout:15" },
				{ icon = "sliders", label = "31 Bands", action = "layout:31" },
			} }),
			button(OWN_SPEAKERS, "Speakers", "speakers", { on = UI.spk }),
			button("speaker", "Device", nil, { menu = devices }),
		} })
		if UI.spk then
			table.insert(whole, { kind = "rule" })
			for _, x in speakers_body(p) do
				table.insert(whole, x)
			end
		end
	end
	return {
		eq = {
			peek = { icon = "sliders", text = if S.on then pre else "Off", dot = edited() or nil },
			tip = if S.on then `{S.current}  {pre}` else "Off",
			wheel = if S.on then "pre_wheel" else nil,
			panel = {
				body = small,
				out = { open = UI.win, remember = true, size = { 680, 640 }, body = whole },
			},
		},
	}
end

-- ---------------------------------------------------------------------------------------------------------------- what happens

local function clamp_band(b: Band)
	b.f = math.clamp(b.f, F_MIN, F_MAX)
	b.g = math.clamp(b.g, G_MIN, G_MAX)
	b.q = math.clamp(b.q, 0.1, 30)
end

local function on_action(a: string, args: any, now: number)
	local p = cur()
	-- (a menu's row: what it names after its colon)
	local verb, what = a:match("^(%a+):(.*)$")
	if verb == "preset" then
		a, args = "preset", { name = what }
	elseif verb == "layout" then
		a, args = "layout", { n = what }
	elseif verb == "device" then
		a, args = "device", { d = what }
	end
	if a == "open_window" then
		UI.win = true
		return
	elseif a == "preset" then
		put_on(args.name)
		apply(now, true)
		save_state()
		return
	elseif a == "power" then
		-- (off: Equalizer APO given back what it read before; on: NADI's again)
		S.on = not S.on
		if S.on then
			apply(now, true)
		else
			table.insert(out_helper, { cmd = "release" })
		end
		save_state()
		return
	elseif a == "step" then
		-- (typed: any step, from a hundredth of a dB to 10)
		local v = tonumber((tostring(args.text or ""):gsub("[^%d%.]", "")))
		if v and v > 0 then
			S.step = math.clamp(math.floor(v * 100 + 0.5) / 100, 0.01, 10)
			save_state()
		end
		return
	elseif a == "speakers" then
		UI.spk = not UI.spk
		return
	elseif a == "guard" then
		S.guard = not S.guard
		if S.guard then
			begin_edit()
			guard_preamp(cur())
			apply(now, true)
		end
		save_state()
		return
	elseif a == "undo" then
		local prev = table.remove(UI.undo)
		if prev then
			table.insert(UI.redo, copy(p))
			S.drafts[S.current] = prev
			apply(now, true)
			save_state()
		end
		return
	elseif a == "redo" then
		local nxt = table.remove(UI.redo)
		if nxt then
			table.insert(UI.undo, copy(p))
			S.drafts[S.current] = nxt
			apply(now, true)
			save_state()
		end
		return
	elseif a == "save" then
		if S.drafts[S.current] then
			S.presets[S.current] = S.drafts[S.current]
			S.drafts[S.current] = nil
			save_state()
		end
		return
	elseif a == "save_new" then
		local n = add_preset(S.current, copy(p))
		S.drafts[S.current] = nil
		put_on(n)
		save_state()
		return
	elseif a == "revert" then
		S.drafts[S.current] = nil
		UI.undo, UI.redo = {}, {}
		apply(now, true)
		save_state()
		return
	elseif a:sub(1, 4) == "dup:" then
		local n = a:sub(5)
		local src = S.drafts[n] or S.presets[n]
		if src then
			put_on(add_preset(n, copy(src)))
			save_state()
		end
		return
	elseif a:sub(1, 4) == "del:" then
		local n = a:sub(5)
		if S.presets[n] and #S.order > 1 then
			S.presets[n] = nil
			S.drafts[n] = nil
			for i, x in S.order do
				if x == n then
					table.remove(S.order, i)
					break
				end
			end
			if S.current == n then
				put_on(S.order[1])
			end
			apply(now, true)
			save_state()
		end
		return
	elseif a == "band_pick" then
		UI.sel = tonumber(args.id) or 0
		return
	end

	-- (the rest change what is heard)
	local drag = a == "band_drag" or a == "preamp" or a == "band_f" or a == "band_g" or a == "band_q" or a:sub(1, 6) == "spk_v:" or a:sub(1, 6) == "spk_d:" or a == "bal" or a == "pre_wheel" or a == "band_wheel"
	local done = args and args.done
	if drag then
		-- (a drag, or the wheel turned: one step for undo, at its start (the same thing again soon after is the same step))
		if not (UI.drag_action == a and now - UI.drag_at < 700) then
			begin_edit()
		end
		UI.drag_action = a
		UI.drag_at = now
	else
		begin_edit()
		UI.drag_action = ""
	end
	p = cur()
	if a == "preamp" then
		local v = PRE_MIN + (PRE_MAX - PRE_MIN) * (args.fraction or 0)
		p.preamp = math.clamp(math.floor(v / S.step + 0.5) * S.step, PRE_MIN, PRE_MAX)
		p.preamp = math.floor(p.preamp * 100 + 0.5) / 100
		guard_preamp(p)
	elseif a == "pre_step" or a == "pre_wheel" or a == "pre_up" or a == "pre_down" then
		local by = if a == "pre_wheel" or a == "pre_up" then (if a == "pre_up" or args.up then S.step else -S.step) elseif a == "pre_down" then -S.step else (tonumber(args.by) or 0)
		p.preamp = math.clamp(p.preamp + by, PRE_MIN, PRE_MAX)
		guard_preamp(p)
	elseif a == "band_drag" then
		local i = tonumber(args.id) or 0
		local b = p.bands[i]
		if b then
			b.f = math.floor(args.x + 0.5)
			if HAS_GAIN[b.t] then
				b.g = math.floor(args.y * 10 + 0.5) / 10
			end
			clamp_band(b)
			UI.sel = i
			if done then
				sort_bands(p)
				for j, x in p.bands do
					if x == b then
						UI.sel = j
					end
				end
			end
		end
		guard_preamp(p)
	elseif a == "band_wheel" then
		local b = p.bands[tonumber(args.id) or 0]
		if b then
			b.q = math.clamp(b.q * (if args.up then 1.1 else 1 / 1.1), 0.1, 30)
			b.q = math.floor(b.q * 100 + 0.5) / 100
			UI.sel = tonumber(args.id) or 0
		end
		guard_preamp(p)
	elseif a == "band_add" then
		local b = { f = math.floor((tonumber(args.x) or 1000) + 0.5), g = math.floor((tonumber(args.y) or 0) * 10 + 0.5) / 10, q = 1.41, t = "PK" }
		clamp_band(b)
		table.insert(p.bands, b)
		sort_bands(p)
		for j, x in p.bands do
			if x == b then
				UI.sel = j
			end
		end
		guard_preamp(p)
	elseif a == "band_remove" then
		if p.bands[UI.sel] then
			table.remove(p.bands, UI.sel)
			UI.sel = 0
		end
	elseif a == "band_type" then
		local b = p.bands[UI.sel]
		if b then
			b.t = args.value or args.t or "PK"
		end
		guard_preamp(p)
	elseif a == "band_hz" or a == "band_db" or a == "band_qq" then
		-- (typed: "2k", "2000", "+5", "1.41")
		local b = p.bands[UI.sel]
		local t = string.lower(tostring(args.text or "")):gsub("[%s,hzdbq+]", "")
		local k = 1
		if t:sub(-1) == "k" then
			k, t = 1000, t:sub(1, -2)
		end
		local v = tonumber(t)
		if b and v then
			if a == "band_hz" then
				b.f = math.floor(v * k + 0.5)
			elseif a == "band_db" then
				b.g = math.floor(v * 10 + 0.5) / 10
			else
				b.q = math.floor(v * 100 + 0.5) / 100
			end
			clamp_band(b)
			if a == "band_hz" then
				sort_bands(p)
				for j, x in p.bands do
					if x == b then
						UI.sel = j
					end
				end
			end
		end
		guard_preamp(p)
	elseif a == "band_f" then
		local b = p.bands[UI.sel]
		if b then
			b.f = math.floor(F_MIN * (F_MAX / F_MIN) ^ (args.fraction or 0) + 0.5)
			clamp_band(b)
		end
	elseif a == "band_g" then
		local b = p.bands[UI.sel]
		if b then
			b.g = math.floor((G_MIN + (G_MAX - G_MIN) * (args.fraction or 0)) * 10 + 0.5) / 10
		end
		guard_preamp(p)
	elseif a == "band_q" then
		local b = p.bands[UI.sel]
		if b then
			b.q = math.floor(0.1 * (30 / 0.1) ^ (args.fraction or 0) * 100 + 0.5) / 100
		end
		guard_preamp(p)
	elseif a == "flatten" then
		for _, b in p.bands do
			b.g = 0
		end
	elseif a == "expand" or a == "compress" then
		local k = if a == "expand" then 1.2 else 1 / 1.2
		for _, b in p.bands do
			b.g = math.clamp(math.floor(b.g * k * 10 + 0.5) / 10, G_MIN, G_MAX)
		end
		guard_preamp(p)
	elseif a == "layout" then
		local fs = LAYOUTS[args.n or "10"] or LAYOUTS["10"]
		local q = if args.n == "31" then 4.32 elseif args.n == "15" then 2.15 else 1.41
		p.bands = {}
		for _, f in fs do
			table.insert(p.bands, { f = f, g = 0, q = q, t = "PK" })
		end
		UI.sel = 0
	elseif a == "channels" then
		p.channels = args.value or args.c or "all"
	elseif a == "device" then
		p.device = args.d or "all"
	elseif a == "mix" then
		p.mix = args.value or args.m or "stereo"
	elseif a == "bal" then
		p.bal = math.floor((-12 + 24 * (args.fraction or 0.5)) * 10 + 0.5) / 10
	elseif a:sub(1, 6) == "spk_v:" then
		local ch = a:sub(7)
		local sp = p.spk[ch] or { v = 0, d = 0 }
		sp.v = math.floor((-20 + 30 * (args.fraction or 0)) * 10 + 0.5) / 10
		p.spk[ch] = sp
	elseif a:sub(1, 6) == "spk_d:" then
		local ch = a:sub(7)
		local sp = p.spk[ch] or { v = 0, d = 0 }
		sp.d = math.floor(30 * (args.fraction or 0) * 10 + 0.5) / 10
		p.spk[ch] = sp
	end
	-- (dragged: heard a few times a second, and once more a moment after it stops; kept then)
	if drag and not done then
		if now - UI.last_apply >= 120 then
			apply(now, true)
		else
			UI.pending = true
		end
	else
		if done then
			UI.drag_action = ""
		end
		apply(now, true)
		UI.pending = false
		save_state()
	end
end

local function on_helper(d: any)
	if d.type == "hello" then
		S.apo = d.apo == true
		S.writable = d.writable ~= false
		S.devices = d.devices or {}
		S.theirs = d.theirs or ""
		local first = not S.ready and (type(d.state) ~= "table" or type(d.state.presets) ~= "table")
		if not S.ready and type(d.state) == "table" and type(d.state.presets) == "table" then
			local st = d.state
			S.on = st.on ~= false
			S.guard = st.guard == true
			S.step = tonumber(st.step) or 0.5
			S.presets, S.drafts = {}, {}
			for n, p in st.presets do
				S.presets[n] = tidy(p)
			end
			for n, p in st.drafts or {} do
				S.drafts[n] = tidy(p)
			end
			S.order = {}
			for _, n in st.order or {} do
				if S.presets[n] then
					table.insert(S.order, n)
				end
			end
			for i, p in st.sets or {} do
				S.sets[tonumber(i) or 0] = tidy(p)
			end
			S.current = st.current or ""
		end
		if S.apo and first then
			first_presets(d)
		end
		if S.current == "" or not S.presets[S.current] then
			S.current = S.order[1] or add_preset("Flat", blank())
		end
		S.ready = true
		if S.apo and S.writable and S.on then
			-- (on at its start: what it had on is heard again; off, Equalizer APO is left as it is)
			apply(0, true)
		end
		save_state()
	elseif d.type == "applied" then
		S.problem = if d.ok then "" else (d.error or "Could not write Equalizer APO's configuration.")
	elseif d.type == "released" then
		S.problem = ""
	end
end

function handle(ev: any): any
	out_helper = {}
	local e = ev.event
	local now = ev.now or 0
	if e == "start" then
		table.insert(out_helper, { cmd = "hello" })
	elseif e == "helper" and type(ev.data) == "table" then
		on_helper(ev.data)
	elseif e == "action" and S.ready then
		on_action(ev.action or "", ev.args or {}, now)
	elseif e == "tick" then
		-- (a drag stopped: what it ended at, heard and kept)
		if UI.pending then
			UI.pending = false
			apply(now, true)
			save_state()
		end
	elseif e == "open" then
		-- (put back by the person: it stays in)
		if ev.widget == "eq" and ev.open == false then
			UI.win = false
		end
	end
	local reply: any = { widgets = widgets() }
	if #out_helper > 0 then
		reply.helper = out_helper
	end
	if UI.pending then
		reply.wake_ms = 200
	end
	if S.problem ~= "" then
		reply.note = S.problem
	elseif S.ready and not S.apo then
		reply.note = "Equalizer APO is not installed."
	else
		reply.note = false
	end
	return reply
end
